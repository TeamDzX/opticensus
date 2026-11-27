import Foundation

/// Everything the tool prints or exports is built here.
public enum Report {
    static let detailOrder = ["path", "file", "client", "scope", "program", "command", "runs", "host",
                              "port", "listens on", "reach", "schedule", "version", "browser"]

    public static func register(_ register: Register, now: Date, only: Kind? = nil, verbose: Bool = false) -> String {
        let items = register.sorted().filter { only == nil || $0.kind == only }
        guard !items.isEmpty else {
            return register.scans == 0 ? "Nothing yet. Run `\(Product.command) scan` first." : "Nothing found."
        }
        var out: [String] = []
        for status in Status.allCases {
            let group = items.filter { $0.status(now: now) == status }
            guard !group.isEmpty else { continue }
            out.append("\(status.title) (\(group.count))")
            for item in group {
                out.append("  \(item.id)  \(pad(item.kind.label, 9))  \(item.name)")
                var facts = detailOrder.compactMap { k in item.detail[k].map { "\(k) \($0)" } }
                if verbose {
                    facts += item.detail.keys.sorted().filter { !detailOrder.contains($0) }.map { "\($0) \(item.detail[$0]!)" }
                    facts.append("first seen \(Format.day(item.firstSeen))")
                    if let v = item.verdict { facts.append("decided by \(v.by) on \(Format.day(v.at))" + (v.reason.isEmpty ? "" : ": \(v.reason)")) }
                } else {
                    facts = Array(facts.prefix(3))
                }
                out.append("          " + facts.joined(separator: " · "))
                let why = item.why(now: now)
                if !why.isEmpty { out.append("          → \(why)") }
            }
            out.append("")
        }
        if let last = register.lastScan { out.append("Last scan \(Format.stamp(last)) · \(items.count) items") }
        return out.joined(separator: "\n")
    }

    public static func events(_ events: [Event]) -> String {
        guard !events.isEmpty else { return "No changes." }
        return events.map { e in
            "\(Format.stamp(e.at))  \(pad(e.type.rawValue.uppercased(), 8)) \(pad(e.kind.label, 9))  \(e.name)"
                + (e.note.isEmpty ? "" : "\n" + String(repeating: " ", count: 20) + e.note)
        }.joined(separator: "\n")
    }

    public static func counts(_ register: Register, now: Date) -> String {
        Status.allCases.map { s in
            "\(register.items.values.filter { $0.status(now: now) == s }.count) \(s.title.lowercased())"
        }.joined(separator: " · ")
    }

    // MARK: export

    struct ExportItem: Encodable {
        var id: String, status: String, why: String
        var item: Item
    }

    struct Export: Encodable {
        var product: String, version: String, signatures: String
        var generatedAt: Date
        var lastScan: Date?
        var items: [ExportItem]
    }

    public static func json(_ register: Register, signatures: Signatures, now: Date) throws -> String {
        let export = Export(product: Product.name, version: Product.version, signatures: signatures.version,
                            generatedAt: now, lastScan: register.lastScan,
                            items: register.sorted().map {
                                ExportItem(id: $0.id, status: $0.status(now: now).rawValue, why: $0.why(now: now), item: $0)
                            })
        return String(decoding: try Store.encoder.encode(export), as: UTF8.self)
    }

    public static func csv(_ register: Register, now: Date) -> String {
        let iso = ISO8601DateFormatter()
        var rows = [["id", "status", "kind", "name", "tool", "present", "open to network", "first seen", "last seen",
                     "verdict", "until", "decided by", "reason", "why", "detail", "key"]]
        for i in register.sorted() {
            rows.append([
                i.id, i.status(now: now).title, i.kind.label, i.name, i.tool ?? "",
                i.present ? "yes" : "no", i.exposed ? "yes" : "no",
                iso.string(from: i.firstSeen), iso.string(from: i.lastSeen),
                i.verdict?.state.rawValue ?? "", i.verdict?.until.map(iso.string) ?? "",
                i.verdict?.by ?? "", i.verdict?.reason ?? "", i.why(now: now),
                i.detail.keys.sorted().map { "\($0)=\(i.detail[$0]!)" }.joined(separator: "; "), i.key,
            ])
        }
        return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    static func csvField(_ s: String) -> String {
        var v = s
        // A cell that starts like a formula is text, not something to run.
        if let first = v.first, "=+-@".contains(first) { v = "'" + v }
        return v.contains(where: { ",\"\n".contains($0) }) ? "\"" + v.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : v
    }

    public static func reads() -> String {
        var out = ["What \(Product.name) reads on this Mac", ""]
        for s in Sources.all { out.append("• " + s.reads) }
        out += ["",
                "Left alone unless you pass --protected: Desktop, Documents, Downloads, Pictures, Movies, Music, iCloud and cloud-storage folders, and external drives. That is why a scan never raises a macOS permission prompt.",
                "What it never keeps: the value of any key or token, prompts or conversations, the contents of your files, full command lines, URLs beyond the host name.",
                "What it cannot see: anything typed into a chatbot in a browser, Safari extensions, editor extensions, network traffic. It reports and tracks; it does not block.",
                "Where findings go: a folder on this Mac (\(Store.defaultDir().path)). Nothing is sent anywhere unless you link WorkFlow (`\(Product.command) workflow connect`): then the name, kind and details of each item that needs you go to WorkFlow as a task, and WorkFlow syncs them through your own iCloud like any other task."]
        return out.joined(separator: "\n")
    }

    static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
}
