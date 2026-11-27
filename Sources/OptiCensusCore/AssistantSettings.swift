import Foundation

/// Where Claude Code, Codex and Gemini keep the settings that decide what an
/// assistant may do without asking. Shared by the plugin, approval and hook
/// sources and by the MCP source (servers that arrive inside a plugin).
enum ClaudeCode {
    struct SettingsFile { var scope: String; var path: String }
    struct Plugin {
        var id: String            // name@marketplace
        var name: String
        var marketplace: String
        var version: String
        var scope: String
        var installPath: String
        var enabled: Bool?
    }

    /// The user's own settings, the machine-wide managed file, and each
    /// project Claude Code has been used in (its shared and local files).
    static func settingsFiles(_ env: Env) -> [SettingsFile] {
        let h = env.home
        var out = [SettingsFile(scope: "user", path: h + "/.claude/settings.json"),
                   SettingsFile(scope: "user (local)", path: h + "/.claude/settings.local.json"),
                   SettingsFile(scope: "managed", path: "/Library/Application Support/ClaudeCode/managed-settings.json")]
        for project in projects(env) {
            let scope = env.tilde(project)
            out.append(SettingsFile(scope: scope, path: project + "/.claude/settings.json"))
            out.append(SettingsFile(scope: scope + " (local)", path: project + "/.claude/settings.local.json"))
        }
        // A project at the home folder shares the user's files: list each file once.
        var seen: Set<String> = []
        return out.filter { env.isFile($0.path) && seen.insert($0.path).inserted }
    }

    static func projects(_ env: Env) -> [String] {
        ((env.json(env.home + "/.claude.json")?["projects"] as? [String: Any]) ?? [:]).keys.sorted()
    }

    static func plugins(_ env: Env) -> [Plugin] {
        let h = env.home
        guard let j = env.json(h + "/.claude/plugins/installed_plugins.json") else { return [] }
        let table = (j["plugins"] as? [String: Any]) ?? j
        let enabled = (env.json(h + "/.claude/settings.json")?["enabledPlugins"] as? [String: Any]) ?? [:]
        var out: [Plugin] = []
        for id in table.keys.sorted() {
            let entries = (table[id] as? [[String: Any]]) ?? ((table[id] as? [String: Any]).map { [$0] } ?? [])
            for e in entries {
                guard let path = e["installPath"] as? String else { continue }
                let parts = id.split(separator: "@", maxSplits: 1).map(String.init)
                out.append(Plugin(id: id, name: parts.first ?? id, marketplace: parts.count > 1 ? parts[1] : "",
                                  version: e["version"] as? String ?? "unknown",
                                  scope: (e["projectPath"] as? String).map(env.tilde) ?? (e["scope"] as? String ?? "user"),
                                  installPath: env.logical(path), enabled: enabled[id] as? Bool))
            }
        }
        return out
    }

    /// The plugin's manifest, from either of the places a plugin keeps it.
    /// Its entry in the marketplace listing comes first, because a plugin
    /// without a manifest of its own (language servers, for one) is declared there.
    static func manifest(_ env: Env, _ p: Plugin) -> [String: Any] {
        var out: [String: Any] = [:]
        let listing = env.home + "/.claude/plugins/marketplaces/\(p.marketplace)/.claude-plugin/marketplace.json"
        if !p.marketplace.isEmpty,
           let entry = ((env.json(listing)?["plugins"] as? [[String: Any]]) ?? []).first(where: { $0["name"] as? String == p.name }) {
            out = entry
        }
        let own = env.json(p.installPath + "/.claude-plugin/plugin.json") ?? env.json(p.installPath + "/plugin.json") ?? [:]
        out.merge(own) { _, mine in mine }
        return out
    }

    /// MCP servers a plugin brings: `mcpServers` in its manifest (inline, or
    /// a path to a file) or an `.mcp.json` beside it.
    static func pluginServers(_ env: Env, _ p: Plugin) -> (file: String, servers: [String: Any])? {
        func servers(in j: [String: Any]) -> [String: Any] {
            (j["mcpServers"] as? [String: Any]) ?? j
        }
        let m = manifest(env, p)
        if let inline = m["mcpServers"] as? [String: Any] {
            return (p.installPath + "/.claude-plugin/plugin.json", inline)
        }
        var candidates = [p.installPath + "/.mcp.json"]
        if let rel = m["mcpServers"] as? String { candidates.insert(resolve(rel, in: p.installPath), at: 0) }
        for file in candidates {
            if let j = env.json(file) { return (file, servers(in: j)) }
        }
        return nil
    }

    /// Hooks a plugin installs: `hooks` in its manifest (inline or a path) or hooks/hooks.json.
    static func pluginHooks(_ env: Env, _ p: Plugin) -> (file: String, hooks: [String: Any])? {
        let m = manifest(env, p)
        if let inline = m["hooks"] as? [String: Any] {
            return (p.installPath + "/.claude-plugin/plugin.json", (inline["hooks"] as? [String: Any]) ?? inline)
        }
        var candidates = [p.installPath + "/hooks/hooks.json"]
        if let rel = m["hooks"] as? String { candidates.insert(resolve(rel, in: p.installPath), at: 0) }
        for file in candidates {
            if let j = env.json(file) { return (file, (j["hooks"] as? [String: Any]) ?? j) }
        }
        return nil
    }

    static func resolve(_ rel: String, in dir: String) -> String {
        rel.hasPrefix("/") ? rel : dir + "/" + rel.replacingOccurrences(of: "./", with: "", options: .anchored)
    }

    /// Canonical text of a JSON value, so the same content always hashes the same.
    static func canonical(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value) || value is [Any],
              let d = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "\(value)" }
        return String(decoding: d, as: UTF8.self)
    }
}

// MARK: - Plugins

struct PluginSource: Source {
    let id = "plugins"
    let reads = "Claude Code plugins: ~/.claude/plugins/installed_plugins.json and each plugin's manifest. Name, version, whether it is switched on, and what it brings (MCP servers, hooks, skills, commands, agents) by count; the contents are kept only as a hash."

    func collect(_ env: Env, _ sig: Signatures) -> [Found] {
        ClaudeCode.plugins(env).map { p in
            let servers = ClaudeCode.pluginServers(env, p)?.servers ?? [:]
            let hooks = ClaudeCode.pluginHooks(env, p)?.hooks ?? [:]
            func count(_ dir: String) -> Int {
                env.list(p.installPath + "/" + dir).filter { !$0.hasPrefix(".") }.count
            }
            let manifest = ClaudeCode.manifest(env, p)
            let lsp = (manifest["lspServers"] as? [String: Any]) ?? env.json(p.installPath + "/.lsp.json") ?? [:]
            func n(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }
            var brings: [String] = []
            if !servers.isEmpty { brings.append(n(servers.count, "MCP server") + " (\(servers.keys.sorted().joined(separator: ", ")))") }
            if !lsp.isEmpty { brings.append(n(lsp.count, "language server") + " (\(lsp.keys.sorted().joined(separator: ", ")))") }
            if !hooks.isEmpty { brings.append("hooks on \(hooks.keys.sorted().joined(separator: ", "))") }
            for (dir, word) in [("skills", "skill"), ("commands", "command"), ("agents", "agent")] {
                let c = count(dir)
                if c > 0 { brings.append(n(c, word)) }
            }
            let state = p.enabled.map { $0 ? "on" : "off" } ?? "not listed in settings"
            return Found(
                kind: .plugin, key: "plugin:claude-code:\(p.scope):\(p.id)", name: p.name, tool: "claude",
                detail: ["marketplace": p.marketplace, "version": p.version, "scope": p.scope,
                         "switched": state, "brings": brings.isEmpty ? "nothing that runs" : brings.joined(separator: "; ")],
                // What it can do, and whether it is on. A version bump alone is an update.
                fingerprint: fingerprint([ClaudeCode.canonical(servers), ClaudeCode.canonical(lsp), ClaudeCode.canonical(hooks), state]),
                version: p.version)
        }
    }
}

// MARK: - Pre-approved actions

struct ApprovalSource: Source {
    let id = "approvals"
    let reads = "What assistants may do without asking: the permission rules and default mode in Claude Code's settings files (yours, the managed one, and each project's), Codex's approval_policy and sandbox_mode, and Gemini's auto-accept switch. Rules are counted by tool; the rules themselves are kept only as a hash."

    static let riskyModes: Set<String> = ["bypassPermissions", "acceptEdits", "dontAsk"]

    func collect(_ env: Env, _ sig: Signatures) -> [Found] {
        var out: [Found] = []
        for f in ClaudeCode.settingsFiles(env) {
            guard let j = env.json(f.path) else { continue }
            let perms = (j["permissions"] as? [String: Any]) ?? [:]
            let allow = ((perms["allow"] as? [Any]) ?? []).map { "\($0)" }
            let mode = perms["defaultMode"] as? String
            let skipsPrompt = j["skipDangerousModePermissionPrompt"] as? Bool == true
            guard !allow.isEmpty || mode.map(Self.riskyModes.contains) == true || skipsPrompt else { continue }
            var detail = ["client": "claude-code", "scope": f.scope, "file": env.tilde(f.path),
                          "pre-approved": allow.isEmpty ? "none" : "\(allow.count) (\(Self.byTool(allow)))"]
            if let mode { detail["default mode"] = mode }
            if skipsPrompt { detail["bypass warning"] = "switched off" }
            out.append(Found(
                kind: .approval, key: "approval:claude-code:\(f.scope)", name: "Claude Code approvals, \(f.scope)",
                tool: "claude", detail: detail,
                fingerprint: fingerprint(allow.sorted() + ["|", mode ?? "", skipsPrompt ? "skip" : ""])))
        }

        // Older Claude Code versions kept a per-project allowedTools list in ~/.claude.json.
        let claudeJSON = env.home + "/.claude.json"
        for (project, value) in ((env.json(claudeJSON)?["projects"] as? [String: Any]) ?? [:]).sorted(by: { $0.key < $1.key }) {
            let tools = (((value as? [String: Any])?["allowedTools"] as? [Any]) ?? []).map { "\($0)" }
            guard !tools.isEmpty else { continue }
            let scope = env.tilde(project)
            out.append(Found(
                kind: .approval, key: "approval:claude-code:\(scope) (allowedTools)",
                name: "Claude Code approvals, \(scope)", tool: "claude",
                detail: ["client": "claude-code", "scope": scope, "file": env.tilde(claudeJSON),
                         "pre-approved": "\(tools.count) (\(Self.byTool(tools)))"],
                fingerprint: fingerprint(tools.sorted())))
        }

        // Codex: top-level keys only, before the first [section].
        let codex = env.home + "/.codex/config.toml"
        if let text = env.text(codex) {
            var fields: [String: String] = [:]
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("[") { break }
                guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
                let k = line[..<eq].trimmingCharacters(in: .whitespaces)
                if k == "approval_policy" || k == "sandbox_mode" {
                    fields[k] = line[line.index(after: eq)...].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                }
            }
            if !fields.isEmpty {
                var detail = ["client": "codex", "file": env.tilde(codex)]
                for (k, v) in fields { detail[k.replacingOccurrences(of: "_", with: " ")] = v }
                out.append(Found(kind: .approval, key: "approval:codex:user", name: "Codex approvals", tool: "codex",
                                 detail: detail, fingerprint: fingerprint(fields.keys.sorted().map { "\($0)=\(fields[$0]!)" })))
            }
        }

        // Gemini CLI: auto-accept, and the tools it may run without asking.
        let gemini = env.home + "/.gemini/settings.json"
        if let j = env.json(gemini) {
            let auto = j["autoAccept"] as? Bool == true
            let allowed = (((j["tools"] as? [String: Any])?["allowed"] as? [Any]) ?? (j["allowedTools"] as? [Any]) ?? []).map { "\($0)" }
            if auto || !allowed.isEmpty {
                out.append(Found(
                    kind: .approval, key: "approval:gemini:user", name: "Gemini approvals", tool: "gemini",
                    detail: ["client": "gemini", "file": env.tilde(gemini), "auto-accept": auto ? "on" : "off",
                             "pre-approved": allowed.isEmpty ? "none" : "\(allowed.count) (\(Self.byTool(allowed)))"],
                    fingerprint: fingerprint(allowed.sorted() + ["|", auto ? "auto" : ""])))
            }
        }
        return out
    }

    /// "Bash 30, WebFetch 5": the tool part of each rule, counted. The
    /// pattern inside the brackets can hold a command line, so it is dropped.
    static func byTool(_ rules: [String]) -> String {
        var counts: [String: Int] = [:]
        for r in rules {
            let tool = r.split(separator: "(", maxSplits: 1).first.map(String.init) ?? r
            counts[tool.trimmingCharacters(in: .whitespaces), default: 0] += 1
        }
        return counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
}

// MARK: - Hooks

struct HookSource: Source {
    let id = "hooks"
    let reads = "Hooks: commands Claude Code runs by itself on assistant events, from its settings files and from installed plugins. The events and the number of commands are recorded; the commands are kept only as a hash."

    func collect(_ env: Env, _ sig: Signatures) -> [Found] {
        var out: [Found] = []
        func add(key: String, name: String, scope: String, file: String, hooks: [String: Any]) {
            guard !hooks.isEmpty else { return }
            var commands = 0
            for case let groups as [Any] in hooks.values {
                for case let g as [String: Any] in groups { commands += (g["hooks"] as? [Any])?.count ?? 1 }
            }
            out.append(Found(
                kind: .hook, key: key, name: name, tool: "claude",
                detail: ["scope": scope, "file": env.tilde(file), "events": hooks.keys.sorted().joined(separator: ", "),
                         "commands": "\(commands) (hash \(fingerprint([ClaudeCode.canonical(hooks)])))"],
                fingerprint: fingerprint([ClaudeCode.canonical(hooks)])))
        }
        for f in ClaudeCode.settingsFiles(env) {
            add(key: "hook:claude-code:\(f.scope)", name: "Claude Code hooks, \(f.scope)", scope: f.scope,
                file: f.path, hooks: (env.json(f.path)?["hooks"] as? [String: Any]) ?? [:])
        }
        for p in ClaudeCode.plugins(env) {
            guard let h = ClaudeCode.pluginHooks(env, p) else { continue }
            add(key: "hook:plugin:\(p.id)", name: "Hooks from plugin \(p.name)", scope: "plugin \(p.id)",
                file: h.file, hooks: h.hooks)
        }
        return out
    }
}

// MARK: - Assistants writing into WorkFlow

/// WorkFlow's Agent Bridge lets assistants create and change tasks. From
/// WorkFlow 6.1 its history names who sent each command; each assistant that
/// wrote there becomes an item, so a new writer is noticed and decided on.
struct WorkFlowWriterSource: Source {
    let id = "workflow-writers"
    let reads = "Assistants writing into WorkFlow: the command history in WorkFlow's Agent Bridge folder (audit.json, WorkFlow 6.1 or later). The assistant's name, how its commands arrived and which kinds of command it sent are recorded; what the commands said is not."

    func collect(_ env: Env, _ sig: Signatures) -> [Found] {
        guard let root = env.json(env.home + "/.workflow-companion/bridge-root.json")?["root"] as? String,
              let data = env.data(root + "/audit.json"),
              let entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        struct Writer { var count = 0; var vias: Set<String> = []; var ops: [String: Int] = [:]; var last = "" }
        var writers: [String: Writer] = [:]
        for e in entries {
            guard let agent = (e["agent"] as? String)?.trimmingCharacters(in: .whitespaces), !agent.isEmpty,
                  agent.caseInsensitiveCompare(WorkFlow.agentName) != .orderedSame,
                  e["via"] as? String != "proposal" else { continue }   // a card the person applied is their own act
            var w = writers[agent, default: Writer()]
            w.count += 1
            if let via = e["via"] as? String { w.vias.insert(via) }
            if let op = e["op"] as? String { w.ops[op, default: 0] += 1 }
            if let at = e["at"] as? String, at > w.last { w.last = at }
            writers[agent] = w
        }
        return writers.keys.sorted().map { agent in
            let w = writers[agent]!
            let ops = w.ops.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.prefix(4).map { "\($0.key) \($0.value)" }
            return Found(
                kind: .writer, key: "writer:workflow:\(agent.lowercased())", name: agent, tool: nil,
                detail: ["writes to": "WorkFlow", "commands": "\(w.count) in WorkFlow's recent history",
                         "through": w.vias.sorted().joined(separator: ", "), "most used": ops.joined(separator: ", "),
                         "last": String(w.last.prefix(16)).replacingOccurrences(of: "T", with: " ")],
                // The assistant is the item. Its routes are shown and recorded as an update:
                // WorkFlow keeps only its last 100 commands, so a route can drop out of view.
                fingerprint: fingerprint([agent.lowercased()]),
                version: w.vias.sorted().joined(separator: ","))
        }
    }
}
