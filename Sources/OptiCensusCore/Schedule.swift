import Foundation

/// The hourly scan: one launch agent, installed and removed only when the
/// owner says so. It runs a copy of the tool kept in the store folder, so
/// rebuilding or moving the original does not break it.
public enum Schedule {
    public static var label: String { "local.\(Product.command).scan" }

    public static var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static func binary(_ storeDir: URL) -> URL { storeDir.appendingPathComponent("bin/\(Product.command)") }
    static func log(_ storeDir: URL) -> URL { storeDir.appendingPathComponent("scan.log") }

    public static func plist(storeDir: URL, minutes: Int) -> [String: Any] {
        ["Label": label,
         "ProgramArguments": [binary(storeDir).path, "--store", storeDir.path, "scan"],
         "StartInterval": minutes * 60,
         "RunAtLoad": true,
         "ProcessType": "Background",
         "StandardOutPath": log(storeDir).path,
         "StandardErrorPath": log(storeDir).path]
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static var domain: String { "gui/\(getuid())" }

    public static var isLoaded: Bool { launchctl(["print", "\(domain)/\(label)"]) == 0 }

    public static func install(storeDir: URL, minutes: Int, from executable: URL) throws -> String {
        let fm = FileManager.default
        let bin = binary(storeDir)
        try fm.createDirectory(at: bin.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: bin.path) { try fm.removeItem(at: bin) }
        try fm.copyItem(at: executable, to: bin)
        try fm.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: plist(storeDir: storeDir, minutes: minutes),
                                           format: .xml, options: 0).write(to: plistURL, options: .atomic)
        launchctl(["bootout", "\(domain)/\(label)"])
        let code = launchctl(["bootstrap", domain, plistURL.path])
        guard code == 0, isLoaded else {
            return "Wrote \(plistURL.path) but launchd did not load it (code \(code))."
        }
        return "Installed: a scan every \(minutes) minutes while this Mac is awake.\n  job   \(plistURL.path)\n  tool  \(bin.path)\n  log   \(log(storeDir).path)\nRemove it with `\(Product.command) schedule uninstall`."
    }

    public static func uninstall(storeDir: URL) throws -> String {
        let fm = FileManager.default
        launchctl(["bootout", "\(domain)/\(label)"])
        var removed: [String] = []
        for url in [plistURL, binary(storeDir)] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
            removed.append(url.path)
        }
        if isLoaded { return "launchd still lists \(label); it was not removed." }
        return removed.isEmpty ? "Nothing was installed." : "Removed:\n  " + removed.joined(separator: "\n  ") + "\nThe register and its history are untouched."
    }

    public static func status(storeDir: URL) -> String {
        let fm = FileManager.default
        var out = [fm.fileExists(atPath: plistURL.path) ? "job file  \(plistURL.path)" : "job file  none",
                   "loaded    \(isLoaded ? "yes" : "no")"]
        if let text = try? String(contentsOf: log(storeDir), encoding: .utf8) {
            let scans = text.split(separator: "\n").filter { $0.hasPrefix("Scanned ") }
            out.append("log       \(scans.count) scans recorded" + (scans.last.map { "; last: \($0)" } ?? ""))
        } else {
            out.append("log       none yet")
        }
        return out.joined(separator: "\n")
    }
}
