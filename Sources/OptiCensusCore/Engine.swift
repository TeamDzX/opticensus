import Foundation

public enum Engine {
    /// Run every source, fold what they saw into the register, and return
    /// what is new or different. Never changes a verdict.
    public static func scan(env: Env, signatures: Signatures, register: inout Register,
                            sources: [Source] = Sources.all) -> [Event] {
        var found: [String: Found] = [:]
        for source in sources {
            for f in source.collect(env, signatures) where found[f.key] == nil { found[f.key] = f }
        }
        return reconcile(found: found, now: env.now, register: &register)
    }

    static func reconcile(found: [String: Found], now: Date, register: inout Register) -> [Event] {
        var events: [Event] = []
        func emit(_ type: Event.EventType, _ item: Item, _ note: String) {
            events.append(Event(at: now, type: type, key: item.key, kind: item.kind, name: item.name, note: note))
        }

        for key in found.keys.sorted() {
            let f = found[key]!
            guard var item = register.items[key] else {
                let item = Item(key: f.key, kind: f.kind, name: f.name, tool: f.tool, detail: f.detail,
                                fingerprint: f.fingerprint, version: f.version, exposed: f.exposed,
                                firstSeen: now, lastSeen: now, present: true, verdict: nil)
                register.items[key] = item
                emit(.new, item, summary(f.detail))
                if f.exposed { emit(.exposed, item, "listening beyond this Mac") }
                continue
            }
            let wasPresent = item.present
            let becameExposed = f.exposed && !(item.exposed && wasPresent)
            if becameExposed {
                emit(.exposed, item, "listening beyond this Mac")
            } else if item.fingerprint != f.fingerprint {
                emit(.changed, item, difference(item.detail, f.detail))
            } else if f.version != nil, item.version != f.version {
                emit(.updated, item, difference(item.detail, f.detail))
            }
            if item.verdict?.state == .denied, !wasPresent {
                emit(.back, item, "marked not allowed on \(Format.day(item.verdict!.at)), present again")
            }
            item.name = f.name; item.tool = f.tool; item.detail = f.detail
            item.fingerprint = f.fingerprint; item.version = f.version; item.exposed = f.exposed
            item.lastSeen = now; item.present = true; item.goneReported = false
            register.items[key] = item
        }

        let limit = TimeInterval(Product.goneAfterDays) * 86_400
        for key in register.items.keys.sorted() where found[key] == nil {
            var item = register.items[key]!
            item.present = false
            if item.verdict?.state == .allowed, !item.kind.isRunningState, !item.goneReported,
               now.timeIntervalSince(item.lastSeen) > limit {
                item.goneReported = true
                emit(.gone, item, "allowed, not seen since \(Format.day(item.lastSeen))")
            }
            register.items[key] = item
        }

        register.lastScan = now
        register.scans += 1
        return events
    }

    // MARK: verdicts

    public enum SelectError: Error, CustomStringConvertible {
        case none(String)
        case several(String, [Item])

        public var description: String {
            switch self {
            case .none(let s): return "Nothing in the register matches \"\(s)\"."
            case .several(let s, let items):
                return "\"\(s)\" matches \(items.count) items; use an id, or add --all:\n"
                    + items.map { "  \($0.id)  \($0.kind.label)  \($0.name)" }.joined(separator: "\n")
            }
        }
    }

    /// An id, a whole key, or a fragment of a key or name.
    public static func select(_ selector: String, in register: Register, all: Bool) throws -> [Item] {
        let items = register.sorted()
        if let exact = items.first(where: { $0.id == selector || $0.key == selector }) { return [exact] }
        let s = selector.lowercased()
        let hits = items.filter { $0.key.lowercased().contains(s) || $0.name.lowercased().contains(s) }
        if hits.isEmpty { throw SelectError.none(selector) }
        if hits.count > 1 && !all { throw SelectError.several(selector, hits) }
        return hits
    }

    public static func decide(_ state: Verdict.State?, keys: [String], until: Date?, by: String, reason: String,
                              now: Date, register: inout Register) -> [Event] {
        var events: [Event] = []
        for key in keys {
            guard var item = register.items[key] else { continue }
            let type: Event.EventType
            if let state {
                item.verdict = Verdict(state: state, until: state == .allowed ? until : nil, by: by,
                                       reason: reason, at: now, fingerprint: item.fingerprint)
                type = state == .allowed ? .allowed : .denied
            } else {
                item.verdict = nil
                type = .cleared
            }
            register.items[key] = item
            var note = "by \(by)"
            if !reason.isEmpty { note += ": \(reason)" }
            if let until, state == .allowed { note += " (until \(Format.day(until)))" }
            events.append(Event(at: now, type: type, key: key, kind: item.kind, name: item.name, note: note))
        }
        return events
    }

    // MARK: wording

    static func summary(_ detail: [String: String]) -> String {
        for k in ["path", "file", "program", "port", "browser"] {
            if let v = detail[k] { return "\(k): \(v)" }
        }
        return ""
    }

    static func difference(_ old: [String: String], _ new: [String: String]) -> String {
        let keys = Set(old.keys).union(new.keys).sorted()
        let parts = keys.compactMap { k -> String? in
            let a = old[k], b = new[k]
            guard a != b else { return nil }
            return "\(k): \(a ?? "none") → \(b ?? "none")"
        }
        return parts.isEmpty ? "contents changed" : parts.joined(separator: "; ")
    }
}
