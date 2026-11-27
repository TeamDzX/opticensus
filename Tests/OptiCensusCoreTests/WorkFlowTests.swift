import XCTest
@testable import OptiCensusCore

/// The WorkFlow link against a fake Agent Bridge folder: commands are read
/// back from inbox/, and WorkFlow's side (receipts, snapshot) is written by hand.
final class WorkFlowTests: XCTestCase {
    var bridge: URL!
    var register = Register()
    var link: WorkFlow.Link!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        bridge = FileManager.default.temporaryDirectory.appendingPathComponent("opticensus-bridge-\(UUID().uuidString)")
        for d in ["inbox", "outbox"] {
            try FileManager.default.createDirectory(at: bridge.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        link = WorkFlow.Link(bridge: bridge.path, connectedAt: now)
        let found = [
            Found(kind: .mcp, key: "mcp:claude-code:user:files", name: "files", detail: ["command": "npx"], fingerprint: "f1"),
            Found(kind: .port, key: "port:11434:ollama", name: "Ollama", detail: ["reach": "the network"],
                  fingerprint: "p1", exposed: true),
        ]
        _ = Engine.reconcile(found: Dictionary(uniqueKeysWithValues: found.map { ($0.key, $0) }), now: now, register: &register)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: bridge) }

    func inbox() throws -> [[String: Any]] {
        let dir = bridge.appendingPathComponent("inbox")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted().map {
            try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent($0))) as! [String: Any]
        }
    }

    /// WorkFlow picks everything up: receipts for each command, inbox emptied.
    func workflowApplies(taskIDs: [String: String] = [:]) throws {
        let dir = bridge.appendingPathComponent("inbox")
        for c in try inbox() {
            let id = c["id"] as! String
            var r: [String: Any] = ["id": id, "op": c["op"]!, "status": "applied", "message": "ok"]
            if c["op"] as? String == "create_task" { r["taskID"] = taskIDs[c["title"] as! String] ?? "T-\(c["title"]!)" }
            try JSONSerialization.data(withJSONObject: r).write(to: bridge.appendingPathComponent("outbox/\(id).json"))
            try FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
        }
    }

    func snapshot(_ tasks: [[String: Any]]) throws {
        try JSONSerialization.data(withJSONObject: ["tasks": tasks]).write(to: bridge.appendingPathComponent("snapshot.json"))
    }

    func sync(_ events: [Event] = [], later: Double = 0) -> WorkFlow.Outcome {
        WorkFlow.sync(link: &link, register: &register, events: events, now: now.addingTimeInterval(later))
    }

    func testEachItemNeedingAPersonBecomesOneTask() throws {
        let first = sync()
        XCTAssertEqual(first.created, 2)
        let sent = try inbox()
        XCTAssertEqual(sent.map { $0["op"] as! String }, ["create_task", "create_task"])
        XCTAssertTrue(sent.allSatisfy { $0["agentName"] as? String == "OptiCensus" && $0["project"] as? String == "OptiCensus" })
        let exposed = try XCTUnwrap(sent.first { ($0["title"] as! String).contains("Ollama") })
        XCTAssertEqual(exposed["title"] as? String, "Check: Ollama (model server port)")
        XCTAssertEqual(exposed["priority"] as? String, "High")
        XCTAssertTrue((exposed["notes"] as! String).contains("Reply to decide"))

        XCTAssertEqual(sync().created, 0, "not sent twice while WorkFlow has not answered")
        try workflowApplies()
        XCTAssertEqual(sync().created, 0, "not sent again once the task exists")
        XCTAssertEqual(link.tasks.count, 2)
    }

    func testAReplyInWorkFlowIsTheDecision() throws {
        sync(); try workflowApplies()
        _ = sync()
        let taskID = link.tasks["mcp:claude-code:user:files"]!.taskID
        try snapshot([["id": taskID, "status": "To Do", "comments": [
            ["id": "c1", "author": "OptiCensus", "authorID": "agent.opticensus", "text": "deny this is me talking"],
            ["id": "c2", "author": "Me", "text": "Allow until 2027-03-31, because it reads the project folder only"],
        ]]])
        let out = sync(later: 60)
        XCTAssertEqual(out.decisions.map(\.type), [.allowed])
        let v = try XCTUnwrap(register.items["mcp:claude-code:user:files"]?.verdict)
        XCTAssertEqual(v.state, .allowed)
        XCTAssertEqual(v.reason, "it reads the project folder only")
        XCTAssertEqual(Format.day(v.until!), "31 Mar 2027")
        XCTAssertEqual(try inbox().map { $0["op"] as! String }, ["add_comment", "complete_task"])
        XCTAssertTrue(link.tasks["mcp:claude-code:user:files"]!.closed)

        // The same reply is not read twice, and an allowed item gets no new task.
        try workflowApplies()
        let again = sync(later: 120)
        XCTAssertTrue(again.decisions.isEmpty)
        XCTAssertEqual(again.created, 0)
    }

    func testAnAllowedItemThatChangesGetsANewTask() throws {
        sync(); try workflowApplies(); _ = sync()
        let key = "mcp:claude-code:user:files"
        try snapshot([["id": link.tasks[key]!.taskID, "status": "To Do", "comments": [["id": "c1", "author": "Me", "text": "allow"]]]])
        _ = sync(later: 60); try workflowApplies()

        let changed = Found(kind: .mcp, key: key, name: "files", detail: ["command": "uvx"], fingerprint: "f2")
        let port = Found(kind: .port, key: "port:11434:ollama", name: "Ollama", detail: [:], fingerprint: "p1", exposed: true)
        let events = Engine.reconcile(found: [key: changed, port.key: port], now: now.addingTimeInterval(3600), register: &register)
        let out = sync(events, later: 3600)
        XCTAssertEqual(out.created, 1)
        XCTAssertEqual(try inbox().first?["title"] as? String, "Decide: files (MCP server)")
    }

    func testATaskClosedWithoutADecisionIsNotReopened() throws {
        sync(); try workflowApplies(); _ = sync()
        try snapshot(link.tasks.values.map { ["id": $0.taskID, "status": "Completed", "comments": []] })
        XCTAssertEqual(sync(later: 60).created, 0)
        XCTAssertEqual(sync(later: 120).created, 0)
    }

    func testRepliesThatAreNotDecisions() {
        XCTAssertNil(WorkFlow.parse("what is this?"))
        XCTAssertNil(WorkFlow.parse("allowance looks fine"), "a longer word is not the verb")
        XCTAssertEqual(WorkFlow.parse("Deny: not ours")?.state, .denied)
        XCTAssertEqual(WorkFlow.parse("deny: not ours")?.reason, "not ours")
        XCTAssertEqual(WorkFlow.parse("ok")?.state, .allowed)
    }

    func testATaskMissingFromAnOldSnapshotIsNotTakenAsDeleted() throws {
        sync(); try workflowApplies(); _ = sync()
        let stamp = ISO8601DateFormatter()
        // Written before WorkFlow had the task: it must stay open.
        try JSONSerialization.data(withJSONObject: ["generatedAt": stamp.string(from: now), "tasks": []])
            .write(to: bridge.appendingPathComponent("snapshot.json"))
        _ = sync(later: 5)
        XCTAssertTrue(link.tasks.values.allSatisfy { !$0.closed })
        // Written well after, and still without it: deleted in WorkFlow.
        try JSONSerialization.data(withJSONObject: ["generatedAt": stamp.string(from: now.addingTimeInterval(600)), "tasks": []])
            .write(to: bridge.appendingPathComponent("snapshot.json"))
        _ = sync(later: 600)
        XCTAssertTrue(link.tasks.values.allSatisfy(\.closed))
    }
}
