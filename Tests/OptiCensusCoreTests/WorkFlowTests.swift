import XCTest
@testable import OptiCensusCore

/// The WorkFlow link against a fake Agent Bridge folder: commands are read
/// back from inbox/, and WorkFlow's side (receipts, snapshot) is written by hand.
final class WorkFlowTests: XCTestCase {
    var bridge: URL!
    var register = Register()
    var link: WorkFlow.Link!
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var cardCodes: [String: String] = [:]   // card summary ("Allow files") -> its proposal code

    override func setUpWithError() throws {
        bridge = FileManager.default.temporaryDirectory.appendingPathComponent("opticensus-bridge-\(UUID().uuidString)")
        for d in ["inbox", "outbox"] {
            try FileManager.default.createDirectory(at: bridge.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        link = WorkFlow.Link(bridge: bridge.path, connectedAt: now)
        link.setupDone = true; link.registerDoc = false      // the older tests look at tasks only
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
            if c["op"] as? String == "propose" {
                let code = "P\(cardCodes.count + 1)"
                r["proposal"] = code
                cardCodes[c["text"] as! String] = code
            }
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
        XCTAssertTrue((exposed["notes"] as! String).contains("tap Apply on the Allow or the Refuse card"))

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
        try workflowApplies()                    // the Allow and Refuse cards went up; WorkFlow took them
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

    func testEachOpenTaskGetsAnAllowAndARefuseCard() throws {
        sync(); try workflowApplies()
        _ = sync()
        let cards = try inbox()
        XCTAssertEqual(cards.map { $0["op"] as! String }, ["propose", "propose", "propose", "propose"])
        let allow = try XCTUnwrap(cards.first { $0["text"] as? String == "Allow files" })
        XCTAssertEqual((allow["proposal"] as? [String: Any])?["op"] as? String, "complete_task")
        try workflowApplies()
        _ = sync(later: 10)
        XCTAssertTrue(try inbox().isEmpty, "cards are not sent twice")
        XCTAssertEqual(link.tasks["mcp:claude-code:user:files"]?.cards?.count, 2)

        // Eight days on, WorkFlow has dropped them: a fresh pair goes up.
        _ = sync(later: 8 * 86_400)
        XCTAssertEqual(try inbox().filter { $0["op"] as? String == "propose" }.count, 4)
    }

    func testApplyingTheRefuseCardIsTheDecision() throws {
        sync(); try workflowApplies(); _ = sync(); try workflowApplies(); _ = sync(later: 5)
        let key = "mcp:claude-code:user:files"
        let code = try XCTUnwrap(cardCodes["Refuse files"])
        try snapshot([["id": link.tasks[key]!.taskID, "status": "Completed", "comments": [
            ["id": "c9", "author": "Me", "text": "✓ Applied \(code)"],
        ]]])
        let out = sync(later: 60)
        XCTAssertEqual(out.decisions.map(\.type), [.denied])
        XCTAssertEqual(register.items[key]?.verdict?.state, .denied)
        XCTAssertEqual(register.items[key]?.verdict?.by, "alex in WorkFlow".replacingOccurrences(of: "alex", with: NSUserName()))
        XCTAssertEqual(try inbox().map { $0["op"] as! String }, ["add_comment"], "applying the card already closed the task")
        XCTAssertTrue(link.tasks[key]!.closed)
    }

    func testADeclinedCardIsNotADecision() throws {
        sync(); try workflowApplies(); _ = sync(); try workflowApplies(); _ = sync(later: 5)
        let key = "mcp:claude-code:user:files"
        try snapshot([["id": link.tasks[key]!.taskID, "status": "To Do", "comments": [
            ["id": "c9", "author": "Me", "text": "✗ Declined \(cardCodes["Allow files"]!) — @OptiCensus: not sure yet"],
        ]]])
        XCTAssertTrue(sync(later: 60).decisions.isEmpty)
        XCTAssertNil(register.items[key]?.verdict)
    }

    func testClearingARefusedItemPutsItBackInWorkFlow() throws {
        sync(); try workflowApplies(); _ = sync(); try workflowApplies(); _ = sync(later: 5)
        let key = "mcp:claude-code:user:files"
        try snapshot([["id": link.tasks[key]!.taskID, "status": "Completed", "comments": [
            ["id": "c9", "author": "Me", "text": "✓ Applied \(cardCodes["Refuse files"]!)"]]]])
        _ = sync(later: 60); try workflowApplies()
        XCTAssertEqual(sync(later: 120).created, 0, "refused: no new task")
        _ = Engine.decide(nil, keys: [key], until: nil, by: "tester", reason: "", now: now.addingTimeInterval(180), register: &register)
        let again = sync(later: 240)
        XCTAssertEqual(again.created, 1)
        XCTAssertEqual(try inbox().last?["title"] as? String, "Decide: files (MCP server)")
    }

    // MARK: setup, My Day, reviews, the register document, team mode

    func ops() throws -> [String] { try inbox().map { $0["op"] as! String } }

    func testSetupHappensOnce() throws {
        link.setupDone = nil
        try snapshot([])
        _ = sync()
        let sent = try inbox()
        XCTAssertEqual(Array(sent.map { $0["op"] as! String }.prefix(3)), ["create_project", "create_smart_list", "create_smart_list"])
        XCTAssertEqual(sent[1]["name"] as? String, "OptiCensus: needs a decision")
        XCTAssertEqual((sent[2]["filters"] as? [String: Any])?["priority"] as? String, "High")
        try workflowApplies()
        _ = sync(later: 5)
        XCTAssertFalse(try ops().contains("create_smart_list"))
    }

    func testAnExistingProjectIsNotCreatedAgain() throws {
        link.setupDone = nil
        try JSONSerialization.data(withJSONObject: ["projects": [["name": "OptiCensus"]], "tasks": []])
            .write(to: bridge.appendingPathComponent("snapshot.json"))
        _ = sync()
        XCTAssertFalse(try ops().contains("create_project"))
    }

    func testUnexpectedItemsGoToMyDay() throws {
        _ = sync()
        let exposed = try XCTUnwrap(try inbox().first { ($0["title"] as! String).contains("Ollama") })
        XCTAssertEqual(exposed["isInMyDay"] as? Bool, true)
        XCTAssertEqual(exposed["dueDate"] as? String, WorkFlow.day(now))
        let plain = try XCTUnwrap(try inbox().first { ($0["title"] as! String).contains("files") })
        XCTAssertNil(plain["isInMyDay"])

        // A model server that opens up while its task is open: flagged for today.
        try workflowApplies(); _ = sync(later: 5); try workflowApplies()
        let back = Event(at: now, type: .exposed, key: "mcp:claude-code:user:files", kind: .mcp, name: "files", note: "listening beyond this Mac")
        _ = sync([back], later: 10)
        let update = try XCTUnwrap(try inbox().first { $0["op"] as? String == "update_task" })
        XCTAssertEqual(update["isInMyDay"] as? Bool, true)
        XCTAssertEqual(update["priority"] as? String, "High")
    }

    func testAReviewTaskComesAWeekBeforeAnAllowanceEnds() throws {
        let key = "mcp:claude-code:user:files"
        sync(); try workflowApplies(); _ = sync(); try workflowApplies()
        let until = now.addingTimeInterval(20 * 86_400)
        try snapshot([["id": link.tasks[key]!.taskID, "status": "To Do", "comments": [
            ["id": "c1", "author": "Me", "text": "allow until \(WorkFlow.day(until)), trial"]]]])
        _ = sync(later: 60); try workflowApplies()
        XCTAssertEqual(sync(later: 5 * 86_400).created, 0, "fifteen days to go: nothing yet")

        let due = sync(later: 14 * 86_400)
        XCTAssertEqual(due.created, 1); XCTAssertEqual(due.reviews, 1)
        let task = try XCTUnwrap(try inbox().first { $0["op"] as? String == "create_task" })
        XCTAssertTrue((task["title"] as! String).hasPrefix("Review: files (allowed until "))
        XCTAssertEqual(task["dueDate"] as? String, WorkFlow.day(Format.parseDay(WorkFlow.day(until), endOfDay: true)!))
        XCTAssertTrue((task["notes"] as! String).contains("trial"))
        try workflowApplies()
        _ = sync(later: 14 * 86_400 + 10)
        let cards = try inbox().filter { $0["op"] as? String == "propose" }.compactMap { $0["text"] as? String }
        XCTAssertTrue(cards.contains("Keep allowing files"))
        try workflowApplies()
        XCTAssertEqual(sync(later: 30 * 86_400).created, 0, "one review per end date, even once it has ended")
    }

    func testTheRegisterIsKeptAsAVersionedDocument() throws {
        link.registerDoc = nil
        _ = sync()
        let file = try XCTUnwrap(try inbox().first { $0["op"] as? String == "attach_file" })
        XCTAssertEqual(file["displayName"] as? String, "OptiCensus AI register.csv")
        XCTAssertEqual(file["project"] as? String, "OptiCensus")
        let staged = bridge.appendingPathComponent("attachments/\(file["fileName"] as! String)")
        XCTAssertTrue(try String(contentsOf: staged, encoding: .utf8).hasPrefix("id,status,kind,name"))
        try workflowApplies()
        _ = sync(later: 5)
        XCTAssertFalse(try ops().contains("add_document_version"), "nothing changed, no new version")
        try workflowApplies()

        _ = Engine.decide(.denied, keys: ["port:11434:ollama"], until: nil, by: "tester", reason: "", now: now, register: &register)
        _ = sync(later: 10)
        let version = try XCTUnwrap(try inbox().first { $0["op"] as? String == "add_document_version" })
        XCTAssertEqual(version["matchTitle"] as? String, "OptiCensus AI register.csv")
        XCTAssertTrue((version["versionComment"] as! String).contains("not allowed"))
    }

    func testADocumentWorkFlowRefusedIsFiledAgain() throws {
        link.registerDoc = nil
        _ = sync()
        let id = try XCTUnwrap(try inbox().first { $0["op"] as? String == "attach_file" })["id"] as! String
        try JSONSerialization.data(withJSONObject: ["id": id, "status": "failed", "message": "No project named “OptiCensus”."])
            .write(to: bridge.appendingPathComponent("outbox/\(id).json"))
        let out = sync(later: 5)
        XCTAssertTrue(out.problems.contains { $0.contains("register document") })
        XCTAssertEqual(try inbox().filter { $0["op"] as? String == "attach_file" }.count, 2, "filed again")
    }

    func testTeamModeNamesTheMacEverywhere() throws {
        link.team = true; link.machine = "Studio Mac"; link.registerDoc = nil
        _ = sync()
        let task = try XCTUnwrap(try inbox().first { ($0["title"] as? String)?.contains("files") == true })
        XCTAssertEqual(task["title"] as? String, "Decide: files (MCP server) · Studio Mac")
        XCTAssertEqual(task["tags"] as? [String], ["OptiCensus", "Studio Mac"])
        XCTAssertTrue((task["notes"] as! String).hasPrefix("Mac: Studio Mac"))
        XCTAssertEqual(try inbox().first { $0["op"] as? String == "attach_file" }?["displayName"] as? String,
                       "OptiCensus AI register (Studio Mac).csv")
        try workflowApplies(); _ = sync(later: 5)
        XCTAssertTrue(try inbox().contains { $0["text"] as? String == "Allow files on Studio Mac" })
    }
}
