import Foundation

/// The register and its history, as two files in one folder:
/// `register.json` (current state) and `events.jsonl` (everything that
/// happened, one line each, never rewritten).
public struct Store {
    public let dir: URL

    public init(dir: URL) { self.dir = dir }

    public static func defaultDir() -> URL {
        if let override = ProcessInfo.processInfo.environment["OPTICENSUS_STORE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Product.name)
    }

    var registerFile: URL { dir.appendingPathComponent("register.json") }
    var eventsFile: URL { dir.appendingPathComponent("events.jsonl") }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static var lineEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func load() throws -> Register {
        guard FileManager.default.fileExists(atPath: registerFile.path) else { return Register() }
        return try Self.decoder.decode(Register.self, from: Data(contentsOf: registerFile))
    }

    public func save(_ register: Register, appending events: [Event]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.encoder.encode(register).write(to: registerFile, options: .atomic)
        guard !events.isEmpty else { return }
        var lines = Data()
        for e in events {
            lines.append(try Self.lineEncoder.encode(e))
            lines.append(0x0A)
        }
        if let handle = try? FileHandle(forWritingTo: eventsFile) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: lines)
        } else {
            try lines.write(to: eventsFile, options: .atomic)
        }
    }

    public func events(since: Date? = nil) -> [Event] {
        guard let text = try? String(contentsOf: eventsFile, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(Event.self, from: Data($0.utf8)) }
            .filter { since == nil || $0.at >= since! }
    }
}
