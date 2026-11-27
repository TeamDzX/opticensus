import Foundation
import CryptoKit

/// The few commands the collector runs. Nothing else is ever executed.
public enum Command: String, CaseIterable {
    case psComm = "ps-comm"     // ps -axo pid=,comm=
    case psArgs = "ps-args"     // ps -axo pid=,args=
    case lsof = "lsof"          // lsof -iTCP -sTCP:LISTEN -nP
    case crontab = "crontab"    // crontab -l

    var launch: (String, [String]) {
        switch self {
        case .psComm: return ("/bin/ps", ["-axo", "pid=,comm="])
        case .psArgs: return ("/bin/ps", ["-axo", "pid=,args="])
        case .lsof: return ("/usr/sbin/lsof", ["-iTCP", "-sTCP:LISTEN", "-nP"])
        case .crontab: return ("/usr/bin/crontab", ["-l"])
        }
    }
}

/// Everything a source may touch. All paths the sources use are logical
/// ("/Applications", "/Users/x/.zshrc"); `root` maps them onto a fixture
/// folder in tests, so no test ever scans the real machine.
public struct Env {
    public var root: URL?
    public var home: String
    public var path: [String]
    public var now: Date
    public var run: (Command) -> String?
    /// Folders macOS guards with a permission prompt are left alone unless
    /// the owner asks, so a scan (above all a scheduled one) never raises one.
    public var includeProtected = false

    static let protected = ["Desktop", "Documents", "Downloads", "Pictures", "Movies", "Music",
                            "Library/Mobile Documents", "Library/CloudStorage"]

    public func blocked(_ path: String) -> Bool {
        if includeProtected { return false }
        if path.hasPrefix("/Volumes/") { return true }
        return Self.protected.contains { path == "\(home)/\($0)" || path.hasPrefix("\(home)/\($0)/") }
    }

    public static func live(now: Date = Date()) -> Env {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        return Env(root: nil, home: NSHomeDirectory(), path: path, now: now, run: { command in
            let (tool, args) = command.launch
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        })
    }

    /// A fixture folder laid out like a Mac: `Applications/`, `Users/<name>/`,
    /// `Library/`, plus `commands/<name>.txt` holding canned command output.
    public static func fixture(root: URL, home: String = "/Users/test", now: Date = Date()) -> Env {
        Env(root: root, home: home, path: ["/usr/local/bin"], now: now, run: { command in
            let f = root.appendingPathComponent("commands/\(command.rawValue).txt")
            return try? String(contentsOf: f, encoding: .utf8)
        })
    }

    // MARK: file access

    public func url(_ logical: String) -> URL {
        guard let root else { return URL(fileURLWithPath: logical) }
        return root.appendingPathComponent(String(logical.drop(while: { $0 == "/" })))
    }

    /// The logical path for a real one (undoes `root`).
    public func logical(_ real: String) -> String {
        guard let root else { return real }
        for prefix in [root.path, root.resolvingSymlinksInPath().path] where real.hasPrefix(prefix) {
            return String(real.dropFirst(prefix.count))
        }
        return real
    }

    public func list(_ dir: String) -> [String] {
        if blocked(dir) { return [] }
        return ((try? FileManager.default.contentsOfDirectory(atPath: url(dir).path)) ?? []).sorted()
    }

    public func isDir(_ path: String) -> Bool {
        if blocked(path) { return false }
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url(path).path, isDirectory: &d) && d.boolValue
    }

    public func isFile(_ path: String) -> Bool {
        if blocked(path) { return false }
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url(path).path, isDirectory: &d) && !d.boolValue
    }

    public func size(_ path: String) -> Int? {
        if blocked(path) { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url(path).path))?[.size] as? Int
    }

    public func data(_ path: String) -> Data? { blocked(path) ? nil : try? Data(contentsOf: url(path)) }

    public func text(_ path: String) -> String? {
        data(path).map { String(decoding: $0, as: UTF8.self) }
    }

    public func json(_ path: String) -> [String: Any]? {
        guard let d = data(path) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// "/Users/x/Library" shown as "~/Library".
    public func tilde(_ path: String) -> String {
        path == home ? "~" : (path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path)
    }
}

/// Short, stable hash of some strings. The only form in which arguments,
/// scripts and permission lists are kept.
public func fingerprint(_ parts: [String]) -> String {
    fingerprint(Data(parts.joined(separator: "\u{0}").utf8))
}

public func fingerprint(_ data: Data) -> String {
    String(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12))
}
