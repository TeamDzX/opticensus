import Foundation

/// WorkFlow as the console: every item that needs a person becomes a task in
/// an "OptiCensus" project, and the person answers on the task, on the Mac or
/// the phone. Each task carries two WorkFlow proposal cards, Allow and
/// Refuse: Apply on one is the decision, and closes the task. A reply that
/// starts with "allow" or "deny" works too.
///
/// It talks to WorkFlow only through the app's Agent Bridge folder: command
/// files into `inbox/`, receipts from `outbox/`, and the app's own
/// `snapshot.json` for the replies. WorkFlow needs no change and must be
/// running for anything to land; until then commands simply wait.
public enum WorkFlow {
    public static let agentName = "OptiCensus"
    public static let tag = "OptiCensus"
    /// WorkFlow drops a proposal card after seven days; a fresh pair goes up then.
    static let cardLifetime: TimeInterval = 7 * 86_400
    static let appliedPrefix = "✓ Applied "

    /// What this Mac remembers about the link, kept as `workflow.json` in the store.
    public struct Link: Codable {
        public struct Task: Codable {
            public var taskID: String
            public var fingerprint: String
            public var verdictAt: Date?
            public var openedAt: Date
            public var closed = false
            public var seenComments: [String] = []
            /// Proposal code -> "allow" or "deny", for the cards on this task.
            public var cards: [String: String]?
            public var cardsAt: Date?
        }
        public var bridge: String
        public var project = WorkFlow.agentName
        public var tasks: [String: Task] = [:]       // item key -> its task
        public var pending: [String: String] = [:]   // command id -> item key, until the receipt names the task
        public var pendingCards: [String: String]?   // command id -> "allow|key" or "deny|key", until the receipt gives the code
        public var connectedAt: Date

        public init(bridge: String, connectedAt: Date) {
            self.bridge = bridge; self.connectedAt = connectedAt
        }

        static func file(_ store: Store) -> URL { store.dir.appendingPathComponent("workflow.json") }

        public static func load(_ store: Store) -> Link? {
            guard let d = try? Data(contentsOf: file(store)) else { return nil }
            return try? Store.decoder.decode(Link.self, from: d)
        }

        public func save(_ store: Store) throws {
            try FileManager.default.createDirectory(at: store.dir, withIntermediateDirectories: true)
            try Store.encoder.encode(self).write(to: Self.file(store), options: .atomic)
        }

        public static func remove(_ store: Store) throws {
            try FileManager.default.removeItem(at: file(store))
        }
    }

    public struct Outcome {
        public var created = 0, carded = 0, commented = 0, closed = 0, waiting = 0
        public var decisions: [Event] = []
        public var problems: [String] = []

        public var summary: String {
            var parts: [String] = []
            if created > 0 { parts.append("\(created) task\(created == 1 ? "" : "s") sent") }
            if carded > 0 { parts.append("Allow and Refuse cards on \(carded) task\(carded == 1 ? "" : "s")") }
            if !decisions.isEmpty { parts.append("\(decisions.count) decision\(decisions.count == 1 ? "" : "s") taken from WorkFlow") }
            if commented > 0 { parts.append("\(commented) comment\(commented == 1 ? "" : "s") posted") }
            if closed > 0 { parts.append("\(closed) task\(closed == 1 ? "" : "s") closed") }
            if waiting > 0 { parts.append("\(waiting) waiting for WorkFlow to pick up") }
            let head = "WorkFlow: " + (parts.isEmpty ? "nothing to send" : parts.joined(separator: ", "))
            return ([head] + problems.map { "  " + $0 }).joined(separator: "\n")
        }
    }

    // MARK: finding the bridge

    /// The folder WorkFlow was told to use for its Agent Bridge: given, from
    /// WF_BRIDGE, or from the file WorkFlow's own command-line tool keeps.
    public static func findBridge(given: String?, home: String = NSHomeDirectory()) -> URL? {
        var candidates: [String] = []
        if let given { candidates.append(given) }
        if let env = ProcessInfo.processInfo.environment["WF_BRIDGE"], !env.isEmpty { candidates.append(env) }
        if let d = try? Data(contentsOf: URL(fileURLWithPath: home + "/.workflow-companion/bridge-root.json")),
           let root = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["root"] as? String {
            candidates.append(root)
        }
        for c in candidates {
            let url = URL(fileURLWithPath: (c as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("inbox").path) { return url }
        }
        return nil
    }

    // MARK: the sync

    /// Read the person's replies, record their decisions, and send what is
    /// new. `events` are the ones the scan that just ran produced.
    public static func sync(link: inout Link, register: inout Register, events: [Event], now: Date) -> Outcome {
        var out = Outcome()
        let bridge = URL(fileURLWithPath: link.bridge)
        let inbox = bridge.appendingPathComponent("inbox"), outbox = bridge.appendingPathComponent("outbox")
        guard FileManager.default.fileExists(atPath: inbox.path) else {
            out.problems.append("No Agent Bridge at \(link.bridge). Turn it on in WorkFlow → Settings → Agent Bridge, then run `\(Product.command) workflow connect`.")
            return out
        }

        // Names sort in the order sent, so WorkFlow applies them in that order.
        let batch = Int(Date().timeIntervalSince1970 * 1000)
        var sequence = 0
        func send(_ op: String, _ fields: [String: Any]) -> String {
            sequence += 1
            let id = "opticensus-\(batch)-\(String(format: "%04d", sequence))-\(UUID().uuidString.prefix(4).lowercased())"
            var command = fields
            command["id"] = id; command["op"] = op; command["agentName"] = agentName
            if let d = try? JSONSerialization.data(withJSONObject: command, options: [.prettyPrinted, .sortedKeys]) {
                // Atomic: the app skips a half-written file, then calls it malformed.
                let tmp = inbox.appendingPathComponent(".\(id).tmp")
                try? d.write(to: tmp)
                try? FileManager.default.moveItem(at: tmp, to: inbox.appendingPathComponent("\(id).json"))
            }
            return id
        }

        // 1. Receipts for tasks sent earlier.
        for (commandID, key) in link.pending.sorted(by: { $0.key < $1.key }) {
            guard let d = try? Data(contentsOf: outbox.appendingPathComponent("\(commandID).json")),
                  let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            link.pending[commandID] = nil
            if r["status"] as? String == "applied", let taskID = r["taskID"] as? String, let item = register.items[key] {
                link.tasks[key] = Link.Task(taskID: taskID, fingerprint: item.fingerprint,
                                            verdictAt: item.verdict?.at, openedAt: now)
            } else {
                out.problems.append("WorkFlow did not take the task for \(register.items[key]?.name ?? key): \(r["message"] as? String ?? "no reason given")")
            }
        }
        for (commandID, tagged) in (link.pendingCards ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let d = try? Data(contentsOf: outbox.appendingPathComponent("\(commandID).json")),
                  let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            link.pendingCards?[commandID] = nil
            let parts = tagged.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2, let code = r["proposal"] as? String, var t = link.tasks[parts[1]] else {
                if r["status"] as? String != "applied" {
                    out.problems.append("WorkFlow did not take a decision card: \(r["message"] as? String ?? "no reason given")")
                }
                continue
            }
            t.cards = (t.cards ?? [:]).merging([code: parts[0]]) { _, new in new }
            link.tasks[parts[1]] = t
        }
        out.waiting = link.pending.count

        // 2. The person's replies, from WorkFlow's snapshot.
        let snapshot = (try? Data(contentsOf: bridge.appendingPathComponent("snapshot.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let tasks = Dictionary(((snapshot?["tasks"] as? [[String: Any]]) ?? []).compactMap { t in
            (t["id"] as? String).map { ($0, t) }
        }, uniquingKeysWith: { a, _ in a })

        for key in link.tasks.keys.sorted() {
            guard var t = link.tasks[key], !t.closed, let item = register.items[key] else { continue }
            guard snapshot != nil else { break }
            guard let task = tasks[t.taskID] else {
                // Deleted in WorkFlow: let it go; a change will open a new one.
                // Only a snapshot written well after the task was made can say
                // so: WorkFlow rewrites it a few seconds after each change.
                if let written = snapshotDate(snapshot?["generatedAt"]), written > t.openedAt.addingTimeInterval(30) {
                    t.closed = true; link.tasks[key] = t
                }
                continue
            }
            let comments = (task["comments"] as? [[String: Any]]) ?? []
            for c in comments {
                guard let cid = c["id"] as? String, !t.seenComments.contains(cid) else { continue }
                t.seenComments.append(cid)
                if (c["authorID"] as? String)?.hasPrefix("agent.") == true { continue }
                let text = c["text"] as? String ?? ""
                var fromCard = false
                var reply = parse(text)
                if text.hasPrefix(appliedPrefix) {
                    let code = String(text.dropFirst(appliedPrefix.count).prefix { !$0.isWhitespace })
                    if let which = t.cards?[code] {
                        reply = Reply(state: which == "allow" ? .allowed : .denied, until: nil, reason: "")
                        fromCard = true
                    }
                }
                guard let reply else { continue }
                let author = (c["author"] as? String).flatMap { $0.isEmpty || $0 == "Me" ? nil : $0 } ?? NSUserName()
                let decided = Engine.decide(reply.state, keys: [key], until: reply.until, by: "\(author) in WorkFlow",
                                            reason: reply.reason, now: now, register: &register)
                out.decisions += decided
                var said = "Recorded: \(reply.state == .allowed ? "allowed" : "not allowed")"
                if let until = reply.until { said += " until \(Format.day(until))" }
                if !reply.reason.isEmpty { said += ". Reason: \(reply.reason)" }
                _ = send("add_comment", ["taskID": t.taskID, "text": said + "."])
                // Applying a card has already closed the task.
                if !fromCard { _ = send("complete_task", ["taskID": t.taskID, "text": said + "."]) }
                out.commented += 1; out.closed += 1
                t.closed = true; t.verdictAt = register.items[key]?.verdict?.at
                break
            }
            if !t.closed, task["status"] as? String == "Completed" {
                t.closed = true                     // closed without a decision: don't nag until it changes
            }
            // Decided on this Mac with the command line while the task was open.
            if !t.closed, let v = item.verdict, v.at > t.openedAt, item.status(now: now) != .needsDecision {
                let said = "Decided on this Mac by \(v.by): \(v.state == .allowed ? "allowed" : "not allowed")"
                    + (v.reason.isEmpty ? "." : ". Reason: \(v.reason).")
                _ = send("complete_task", ["taskID": t.taskID, "text": said])
                out.closed += 1
                t.closed = true; t.verdictAt = v.at
            }
            link.tasks[key] = t
        }

        // 2b. Allow and Refuse cards on every open task that has none (or whose cards have lapsed).
        let carding = Set((link.pendingCards ?? [:]).values.compactMap { $0.split(separator: "|", maxSplits: 1).last.map(String.init) })
        for key in link.tasks.keys.sorted() {
            guard var t = link.tasks[key], !t.closed, !carding.contains(key), let item = register.items[key] else { continue }
            if let at = t.cardsAt, now.timeIntervalSince(at) < cardLifetime { continue }
            for (which, summary, reason) in [
                ("allow", "Allow \(item.name)", "It stays on the allowed list. \(Product.name) asks again only if it changes."),
                ("deny", "Refuse \(item.name)", "It is marked not allowed, and flagged at every scan while it is still here."),
            ] {
                let id = send("propose", ["taskID": t.taskID, "text": summary, "reason": reason,
                                          "proposal": ["op": "complete_task", "text": "\(summary): decided in WorkFlow."]])
                link.pendingCards = (link.pendingCards ?? [:]).merging([id: "\(which)|\(key)"]) { _, new in new }
            }
            t.cards = [:]; t.cardsAt = now
            out.carded += 1
            link.tasks[key] = t
        }

        // 3. What happened in this scan, on the open task it concerns.
        for e in events where [.changed, .exposed, .back, .gone].contains(e.type) {
            guard let t = link.tasks[e.key], !t.closed else { continue }
            _ = send("add_comment", ["taskID": t.taskID, "text": "\(e.type.rawValue.capitalized): \(e.note)"])
            out.commented += 1
        }

        // 4. A task for everything that needs a person and has none open.
        let waitingKeys = Set(link.pending.values)
        for item in register.sorted() {
            let status = item.status(now: now)
            guard item.present, status == .needsDecision || status == .unexpected,
                  !waitingKeys.contains(item.key) else { continue }
            if let t = link.tasks[item.key] {
                if !t.closed { continue }
                // Closed before: only a real change, or a decision since, reopens it.
                if t.fingerprint == item.fingerprint && t.verdictAt == item.verdict?.at { continue }
            }
            var fields: [String: Any] = ["title": title(item, now: now), "project": link.project,
                                         "notes": notes(item, now: now), "tags": [tag]]
            if status == .unexpected { fields["priority"] = "High" }
            let id = send("create_task", fields)
            link.pending[id] = item.key
            link.tasks[item.key] = nil
            out.created += 1
        }
        out.waiting = link.pending.count - out.created
        if out.waiting < 0 { out.waiting = 0 }
        return out
    }

    static func snapshotDate(_ value: Any?) -> Date? {
        guard let s = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: wording

    static func title(_ item: Item, now: Date) -> String {
        let what: String
        switch item.kind {
        case .app: what = "app"
        case .process: what = "running program"
        case .autostart: what = "start-up job"
        case .mcp: what = "MCP server"
        case .port: what = "model server port"
        case .cli: what = "command-line assistant"
        case .key: what = "AI key name"
        case .extension: what = "browser extension"
        case .plugin: what = "Claude Code plugin"
        case .approval: what = "pre-approved actions"
        case .hook: what = "hooks"
        }
        let verb = item.status(now: now) == .unexpected ? "Check" : "Decide"
        return "\(verb): \(item.name) (\(what))"
    }

    static func notes(_ item: Item, now: Date) -> String {
        var lines = [item.why(now: now).prefix(1).uppercased() + item.why(now: now).dropFirst() + ".", ""]
        for k in item.detail.keys.sorted() { lines.append("\(k): \(item.detail[k]!)") }
        lines += ["first seen: \(Format.day(item.firstSeen))", "id: \(item.id)", "",
                  "To decide, tap Apply on the Allow or the Refuse card below.",
                  "Or reply with a reason: \"allow, because ...\", \"allow until 2027-03-31, ...\" or \"deny, because ...\".",
                  "\(Product.name) records it at its next scan."]
        return lines.joined(separator: "\n")
    }

    struct Reply { var state: Verdict.State; var until: Date?; var reason: String }

    /// "allow, used for client work", "Deny: not ours", "allow until 2027-03-31 trial".
    static func parse(_ text: String) -> Reply? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = t.prefix { $0.isLetter }.lowercased()
        let state: Verdict.State
        switch first {
        case "allow", "allowed", "approve", "approved", "yes", "ok", "okay", "keep": state = .allowed
        case "deny", "denied", "refuse", "refused", "no", "block", "remove", "reject": state = .denied
        default: return nil
        }
        var rest = String(t.dropFirst(first.count))
        func trimLead(_ s: String) -> String {
            String(s.drop { $0 == " " || $0 == "," || $0 == ":" || $0 == "." || $0 == "-" || $0 == "—" })
        }
        rest = trimLead(rest)
        var until: Date?
        if state == .allowed, rest.lowercased().hasPrefix("until ") {
            let dateText = String(rest.dropFirst(6).prefix(10))
            if let d = Format.parseDay(dateText, endOfDay: true) {
                until = d
                rest = trimLead(String(rest.dropFirst(6 + 10)))
            }
        }
        for lead in ["because ", "since "] where rest.lowercased().hasPrefix(lead) {
            rest = String(rest.dropFirst(lead.count))
        }
        return Reply(state: state, until: until, reason: rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
