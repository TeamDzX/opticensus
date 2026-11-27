import Foundation
import OptiCensusCore

let usage = """
\(Product.command) \(Product.version): every AI on this Mac that can touch your work, whether you
allowed it, and what changed since you last looked.

  \(Product.command) scan [--json]                 Look now; print what is new or different
  \(Product.command) show [KIND] [-v] [--json]     The register, grouped by what needs doing
  \(Product.command) diff [--since YYYY-MM-DD]     What changed in the last scan, or since a date
  \(Product.command) allow ITEM [--until YYYY-MM-DD] [--reason TEXT] [--by NAME] [--all]
  \(Product.command) deny ITEM [--reason TEXT] [--by NAME] [--all]
  \(Product.command) clear ITEM [--all]            Remove a decision
  \(Product.command) export [--csv] [-o FILE]      The whole register, JSON unless --csv
  \(Product.command) schedule install|status|uninstall [--every MINUTES]
                                       A background scan (hourly unless told otherwise)
  \(Product.command) workflow connect|status|sync|disconnect [--bridge DIR]
                                       Use the WorkFlow app as the console: a task for each
                                       item that needs you; reply "allow" or "deny" there
  \(Product.command) reads                         What this tool reads, and what it never keeps

ITEM is the six-character id from `show`, or part of a name or key.
KIND is one of: \(Kind.allCases.map(\.rawValue).joined(separator: ", ")).

Options for every command:
  --store DIR     Keep the register here (default: ~/Library/Application Support/\(Product.name))
  --fixture DIR   Scan a fixture folder instead of this Mac (for tests and demos)
  --protected     Also look inside Desktop, Documents, Downloads, iCloud and external
                  drives (macOS may ask for permission; left out by default)
"""

struct Fail: Error { let message: String }

var args = Array(CommandLine.arguments.dropFirst())

func flag(_ name: String) -> Bool {
    guard let i = args.firstIndex(of: name) else { return false }
    args.remove(at: i)
    return true
}

func option(_ name: String) throws -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { throw Fail(message: "\(name) needs a value.") }
    let value = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return value
}

func day(_ name: String, endOfDay: Bool) throws -> Date? {
    guard let s = try option(name) else { return nil }
    guard let d = Format.parseDay(s, endOfDay: endOfDay) else {
        throw Fail(message: "\(name) wants a date like 2027-03-31, not \"\(s)\".")
    }
    return d
}

func run() throws {
    let storeDir = try option("--store").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    let fixture = try option("--fixture").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    let json = flag("--json")
    guard let command = args.first else { print(usage); return }
    args.removeFirst()

    var env = fixture.map { Env.fixture(root: $0) } ?? Env.live()
    env.includeProtected = flag("--protected")
    // A fixture never writes into the real register.
    let store = Store(dir: storeDir ?? fixture?.appendingPathComponent("store") ?? Store.defaultDir())
    let signatures = Signatures.load(storeDir: store.dir)
    var register = try store.load()
    let now = env.now

    switch command {
    case "scan":
        let events = Engine.scan(env: env, signatures: signatures, register: &register)
        try store.save(register, appending: events)
        let synced = fixture == nil ? try syncWorkFlow(store: store, register: &register, events: events, now: now) : nil
        if json {
            print(String(decoding: try JSONEncoder.report.encode(events + (synced?.decisions ?? [])), as: UTF8.self))
        } else {
            print(Report.events(events))
            print("Scanned \(Format.stamp(now)) · \(register.items.values.filter(\.present).count) present · " + Report.counts(register, now: now))
            if let synced { print(synced.summary) }
        }

    case "show":
        let verbose = flag("-v") || flag("--verbose")
        var only: Kind?
        if let k = args.first {
            guard let kind = Kind(rawValue: k) else { throw Fail(message: "Unknown kind \"\(k)\".") }
            only = kind
        }
        if json {
            var filtered = register
            if let only { filtered.items = register.items.filter { $0.value.kind == only } }
            print(try Report.json(filtered, signatures: signatures, now: now))
        } else {
            print(Report.register(register, now: now, only: only, verbose: verbose))
        }

    case "diff":
        let since = try day("--since", endOfDay: false) ?? register.lastScan
        let events = store.events(since: since)
        if json {
            print(String(decoding: try JSONEncoder.report.encode(events), as: UTF8.self))
        } else {
            print(Report.events(events))
        }

    case "allow", "deny", "clear":
        let all = flag("--all")
        let until = try day("--until", endOfDay: true)
        let reason = try option("--reason") ?? ""
        let by = try option("--by") ?? NSUserName()
        guard let selector = args.first else { throw Fail(message: "Say which item: an id from `\(Product.command) show`.") }
        let items = try Engine.select(selector, in: register, all: all)
        let state: Verdict.State? = command == "allow" ? .allowed : command == "deny" ? .denied : nil
        let events = Engine.decide(state, keys: items.map(\.key), until: until, by: by, reason: reason,
                                   now: now, register: &register)
        try store.save(register, appending: events)
        print(Report.events(events))
        if fixture == nil, let synced = try syncWorkFlow(store: store, register: &register, events: [], now: now) {
            print(synced.summary)
        }

    case "workflow":
        guard fixture == nil else { throw Fail(message: "A fixture cannot be linked to WorkFlow.") }
        let given = try option("--bridge")
        switch args.first ?? "status" {
        case "connect":
            guard let bridge = WorkFlow.findBridge(given: given) else {
                throw Fail(message: """
                No WorkFlow Agent Bridge found. In WorkFlow: Settings → Agent Bridge → switch it on and
                choose a Bridge Folder, then run this again (or pass --bridge FOLDER).
                """)
            }
            var link = WorkFlow.Link.load(store) ?? WorkFlow.Link(bridge: bridge.path, connectedAt: now)
            link.bridge = bridge.path
            try link.save(store)
            print("Linked to WorkFlow through \(bridge.path).")
            print("Each item that needs you becomes a task in the \"\(link.project)\" project. Reply \"allow\" or \"deny\" on it,")
            print("with a reason if you like; the next scan records it. WorkFlow has to be running for tasks to appear.")
            print("If WorkFlow asks you to OK each task it closes, set Settings → Agent Bridge → Briefs, Check-ins &")
            print("Approvals → \(WorkFlow.agentName) → Ask before: Nothing. Its replies and closings then land on their own.")
            if let synced = try syncWorkFlow(store: store, register: &register, events: [], now: now) { print(synced.summary) }
        case "sync":
            guard let synced = try syncWorkFlow(store: store, register: &register, events: [], now: now) else {
                throw Fail(message: "Not linked to WorkFlow. Run `\(Product.command) workflow connect`.")
            }
            print(synced.summary)
        case "status":
            guard let link = WorkFlow.Link.load(store) else { print("Not linked to WorkFlow."); return }
            let open = link.tasks.values.filter { !$0.closed }.count
            print("Linked to WorkFlow since \(Format.day(link.connectedAt)) through \(link.bridge)")
            print("\(open) open task\(open == 1 ? "" : "s") in \"\(link.project)\", \(link.pending.count) waiting for WorkFlow to pick up")
        case "disconnect":
            guard WorkFlow.Link.load(store) != nil else { print("Not linked to WorkFlow."); return }
            try WorkFlow.Link.remove(store)
            print("Unlinked. Tasks already in WorkFlow stay there; nothing more is sent.")
        default:
            throw Fail(message: "workflow takes connect, status, sync or disconnect.")
        }

    case "export":
        let csv = flag("--csv")
        let out = try option("-o") ?? option("--output")
        let text = csv ? Report.csv(register, now: now) : try Report.json(register, signatures: signatures, now: now)
        if let out {
            try text.write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
            print("Wrote \(register.items.count) items to \(out)")
        } else {
            print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
        }

    case "schedule":
        guard fixture == nil else { throw Fail(message: "A fixture cannot be scheduled.") }
        let minutes = try option("--every").map { Int($0) ?? 0 } ?? 60
        guard minutes >= 5 else { throw Fail(message: "--every wants minutes, 5 or more.") }
        switch args.first ?? "status" {
        case "install":
            let me = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
            print(try Schedule.install(storeDir: store.dir, minutes: minutes, from: me))
        case "uninstall": print(try Schedule.uninstall(storeDir: store.dir))
        case "status": print(Schedule.status(storeDir: store.dir))
        default: throw Fail(message: "schedule takes install, status or uninstall.")
        }

    case "reads":
        print(Report.reads())

    case "help", "-h", "--help":
        print(usage)

    case "version", "--version":
        print("\(Product.command) \(Product.version) · signatures \(signatures.version)")

    default:
        throw Fail(message: "Unknown command \"\(command)\". Try `\(Product.command) help`.")
    }
}

/// When linked, hand the person's replies in and the new items out. Decisions
/// taken from WorkFlow are saved with the register.
func syncWorkFlow(store: Store, register: inout Register, events: [Event], now: Date) throws -> WorkFlow.Outcome? {
    guard var link = WorkFlow.Link.load(store) else { return nil }
    let outcome = WorkFlow.sync(link: &link, register: &register, events: events, now: now)
    try link.save(store)
    try store.save(register, appending: outcome.decisions)
    return outcome
}

extension JSONEncoder {
    static var report: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

do {
    try run()
} catch let e as Fail {
    FileHandle.standardError.write(Data((e.message + "\n").utf8))
    exit(2)
} catch let e as Engine.SelectError {
    FileHandle.standardError.write(Data((e.description + "\n").utf8))
    exit(2)
} catch {
    FileHandle.standardError.write(Data("\(Product.command): \(error.localizedDescription)\n".utf8))
    exit(1)
}
