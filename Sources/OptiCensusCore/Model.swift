import Foundation

public enum Kind: String, Codable, CaseIterable {
    case app, process, autostart, mcp, port, cli, key, `extension`, plugin, approval, hook, writer

    public var label: String {
        switch self {
        case .app: return "app"
        case .process: return "running"
        case .autostart: return "autostart"
        case .mcp: return "mcp"
        case .port: return "port"
        case .cli: return "cli"
        case .key: return "key"
        case .extension: return "extension"
        case .plugin: return "plugin"
        case .approval: return "approval"
        case .hook: return "hook"
        case .writer: return "writer"
        }
    }

    /// Running state comes and goes; it is never reported as "gone".
    var isRunningState: Bool { self == .process || self == .port }
}

/// What one source saw in one scan.
public struct Found {
    public var kind: Kind
    public var key: String
    public var name: String
    public var tool: String?
    public var detail: [String: String]
    /// Changes when what the item is or can do changes. A change here puts
    /// an allowed item back in front of a person.
    public var fingerprint: String
    /// Changes on an ordinary update. Recorded, never revokes a verdict.
    public var version: String?
    public var exposed: Bool

    public init(kind: Kind, key: String, name: String, tool: String? = nil,
                detail: [String: String] = [:], fingerprint: String,
                version: String? = nil, exposed: Bool = false) {
        self.kind = kind; self.key = key; self.name = name; self.tool = tool
        self.detail = detail; self.fingerprint = fingerprint
        self.version = version; self.exposed = exposed
    }
}

public struct Verdict: Codable, Equatable {
    public enum State: String, Codable { case allowed, denied }
    public var state: State
    public var until: Date?
    public var by: String
    public var reason: String
    public var at: Date
    /// The item's fingerprint when the decision was made.
    public var fingerprint: String
}

public enum Status: String, Codable, CaseIterable {
    case needsDecision, unexpected, allowed, notAllowed

    public var title: String {
        switch self {
        case .needsDecision: return "Needs a Decision"
        case .unexpected: return "Unexpected"
        case .allowed: return "Allowed"
        case .notAllowed: return "Not Allowed"
        }
    }
}

public struct Item: Codable {
    public var key: String
    public var kind: Kind
    public var name: String
    public var tool: String?
    public var detail: [String: String]
    public var fingerprint: String
    public var version: String?
    public var exposed: Bool
    public var firstSeen: Date
    public var lastSeen: Date
    public var present: Bool
    public var verdict: Verdict?
    public var goneReported: Bool = false

    /// Six characters to type instead of the key.
    public var id: String { String(OptiCensusCore.fingerprint([key]).prefix(6)) }

    public var changedSinceVerdict: Bool {
        verdict.map { $0.fingerprint != fingerprint } ?? false
    }

    public func status(now: Date) -> Status {
        guard let v = verdict else { return exposed && present ? .unexpected : .needsDecision }
        switch v.state {
        case .denied:
            return present ? .unexpected : .notAllowed
        case .allowed:
            if let until = v.until, until < now { return .needsDecision }
            if changedSinceVerdict { return exposed && present ? .unexpected : .needsDecision }
            return .allowed
        }
    }

    /// Why the item sits where it does, in a few words.
    public func why(now: Date) -> String {
        var notes: [String] = []
        if let v = verdict {
            switch v.state {
            case .denied:
                notes.append(present ? "not allowed, but present" : "not allowed, absent")
            case .allowed:
                if let until = v.until, until < now {
                    notes.append("allowance ended \(Format.day(until))")
                } else if changedSinceVerdict {
                    notes.append("changed since it was allowed")
                } else if let until = v.until {
                    notes.append("allowed until \(Format.day(until))")
                }
            }
        } else {
            notes.append("no decision yet")
        }
        if exposed && present { notes.append("open to the network") }
        if !present && verdict?.state != .denied { notes.append("not present now") }
        return notes.joined(separator: " · ")
    }
}

public struct Event: Codable {
    public enum EventType: String, Codable {
        case new, changed, updated, exposed, back, gone, allowed, denied, cleared
    }
    public var at: Date
    public var type: EventType
    public var key: String
    public var kind: Kind
    public var name: String
    public var note: String
}

public struct Register: Codable {
    public var schema = 1
    public var items: [String: Item] = [:]
    public var lastScan: Date?
    public var scans = 0

    public init() {}

    public func sorted() -> [Item] {
        items.values.sorted { ($0.kind.rawValue, $0.name.lowercased(), $0.key) < ($1.kind.rawValue, $1.name.lowercased(), $1.key) }
    }
}

public enum Format {
    public static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.dateFormat = "d MMM yyyy"
        return f.string(from: d)
    }

    public static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.dateFormat = "d MMM yyyy HH:mm"
        return f.string(from: d)
    }

    /// yyyy-MM-dd, read as the end of that day in local time.
    public static func parseDay(_ s: String, endOfDay: Bool) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: s) else { return nil }
        return endOfDay ? d.addingTimeInterval(86_399) : d
    }
}
