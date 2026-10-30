import AgentTeamCore
import Foundation

// Assert-based self-check (no XCTest with Command Line Tools). Run: swift run AgentTeamChecks
var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}

// Parsers & Limit Detection
do {
    var p = OutputParser(.claude)
    check(p.feed(#"{"type":"system","subtype":"init","session_id":"s1"}"#) == [.session("s1")], "claude init")
    check(p.feed(#"{"type":"system","subtype":"init","session_id":"s1","model":"claude-3-5-sonnet-20241022"}"#) == [.session("s1"), .modelMetadata("claude-3-5-sonnet-20241022")], "claude init with model metadata")
    check(p.feed(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#) == [.progress("🔧 Bash ls")], "claude tool")
    check(p.feed(#"{"type":"result","subtype":"success","is_error":false,"result":"OK","session_id":"s1"}"#) == [.session("s1"), .final("OK")], "claude result")
    check(p.feed(#"{"type":"result","subtype":"success","is_error":true,"result":"Claude AI usage limit reached"}"#) == [.failure("Claude AI usage limit reached")], "claude error")

    var c = OutputParser(.codex)
    check(c.feed(#"{"type":"thread.started","thread_id":"t1"}"#) == [.session("t1")], "codex thread")
    _ = c.feed(#"{"type":"item.completed","item":{"id":"i","type":"agent_message","text":"Done."}}"#)
    check(c.feed(#"{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":5}}"#) == [.usage(25), .final("Done.")], "codex final + usage")
    check(c.feed(#"{"type":"turn.failed","error":{"message":"You've hit your usage limit."}}"#) == [.failure("You've hit your usage limit.")], "codex failed")

    var a = OutputParser(.antigravity)
    check(a.feed(#"{"event":"step_update","step_update":{"conversation_id":"g1","step_type":"agent_response","text_delta":"Hi"}}"#) == [.session("g1")], "agy step")
    check(a.feed(#"{"event":"result","result":{"conversation_id":"g1","status":"SUCCESS","response":"Hello"}}"#) == [.session("g1"), .final("Hello")], "agy result")
    check(a.feed("not json") == [], "garbage ignored")

    // R2: Positive contextual limit detection
    check(isLimitError("Claude AI usage limit reached"), "claude usage limit")
    check(isLimitError("You've hit your usage limit."), "codex usage limit")
    check(isLimitError("RESOURCE_EXHAUSTED"), "agy resource exhausted")
    check(isLimitError("HTTP 429 Too Many Requests"), "http 429")
    check(isLimitError("status: 429"), "status 429")
    check(isLimitError("error: 429"), "error: 429")
    check(isLimitError(#"API Error: 429 {"type":"rate_limit_error"}"#), "api error 429")
    check(isLimitError("insufficient_quota"), "insufficient quota")
    check(isLimitError("quota exceeded for model"), "quota exceeded")

    // R2: Negative cases (must NOT match bare 429 or bare quota)
    check(!isLimitError("see main.swift line 429 for details"), "negative line 429 details")
    check(!isLimitError("exit 1: processed 429 files"), "negative processed 429 files")
    check(!isLimitError("File.swift:429: error: index out of range"), "negative line 429")
    check(!isLimitError("/var/log/app/429/output.log"), "negative path 429")
    check(!isLimitError("Request ID: req_429184"), "negative request id 429")
    check(!isLimitError("The user has a quota of 10 pull requests per day."), "negative agent text quota")
    check(!isLimitError("exit 1: command not found"), "negative general error")
}

// Isolate Quota and Team template tests so they never touch ~/Library/Application Support/AgentTeam
let tempQuotaDir = FileManager.default.temporaryDirectory.appendingPathComponent("quota-test-\(shortId())")
try FileManager.default.createDirectory(at: tempQuotaDir, withIntermediateDirectories: true)
Quota.fileOverride = tempQuotaDir.appendingPathComponent("quota.json")
Quota.workDirOverride = tempQuotaDir.appendingPathComponent("agy-usage")
Quota.codexSessionsOverride = tempQuotaDir.appendingPathComponent("codex_sessions")

// Built-in template: the user's chosen roles/providers; Planner and Critic stay on different model families.
do {
    var t = Team.starter()
    check(Set(t.roles.map(\.id)) == ["lead", "planner", "critic", "worker", "testing"], "template roles")
    func provider(_ role: String) -> Provider? { t.agents.first { $0.roleId == role }.flatMap(t.effectiveProfile)?.provider }
    check(provider("planner") != provider("critic"), "planner/critic differ")
    check(provider("worker") == .antigravity && t.maxConcurrent == 5 && t.debateRounds == 3 && t.maxAutoTurns == 30, "starter settings")
    t.disabledProviders = [.claude]
    check(provider("planner") == .codex && provider("testing") == .antigravity, "Claude off: planner/testing fall back")
    t.disabledProviders = []
    t.limitedProviders = [.claude]
    check(t.agents.first { $0.roleId == "testing" }.flatMap(t.effectiveProfile) == Profile(.antigravity, "gemini-3.8-flash-high"),
          "limited Testing uses fallback #1 first")
    t.limitedProviders = [.claude, .antigravity]
    check(t.agents.first { $0.roleId == "testing" }.flatMap(t.effectiveProfile) == Profile(.codex, "gpt-6-luna", effort: "medium"),
          "then fallback #2")
}

// Older team.json without newer optional fields still decodes (no reset to template).
do {
    var json = try JSONSerialization.jsonObject(with: jsonEncoder.encode(Team.starter())) as! [String: Any]
    json.removeValue(forKey: "debateRounds")
    check((try? jsonDecoder.decode(Team.self, from: JSONSerialization.data(withJSONObject: json))) != nil, "old team.json decodes")
}

// Verified model helper tests
do {
    let claudeProf = Profile(.claude, "sonnet")
    let codexProf = Profile(.codex, "gpt-6.1-sol")
    var c = Chat(agentId: "w", title: "test")
    c.sessionProfile = claudeProf
    c.reportedModel = "claude-3-7-sonnet"
    c.reportedModelProvider = "claude"

    // cùng profile: trả model
    check(c.verifiedModel(for: claudeProf) == "claude-3-7-sonnet", "verifiedModel matching profile returns model")

    // phiên Claude, profile hiện tại Codex: nil
    check(c.verifiedModel(for: codexProf) == nil, "verifiedModel mismatched profile returns nil")

    // reportedModelProvider bằng nil: nil
    c.reportedModelProvider = nil
    check(c.verifiedModel(for: claudeProf) == nil, "verifiedModel nil provider returns nil")
}

// Quota parsing
do {
    var p = OutputParser(.claude)
    let ev = p.feed(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.31,"resetsAt":1793277600},"seven_day":{"utilization":0.41,"resetsAt":1793613600}}}}"#)
    if case .quota(let w) = ev.first {
        check(w.map(\.name) == ["5 giờ", "7 ngày"] && Int(w[0].usedPercent.rounded()) == 31, "claude quota \(w)")
    } else { check(false, "claude quota event") }

    let home = FileManager.default.temporaryDirectory.appendingPathComponent("codexhome-\(shortId())")
    let dir = home.appendingPathComponent(".codex/sessions/2026/10/29")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try """
    {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1793774512},"secondary":null}}}
    {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":71.0,"window_minutes":10080,"resets_at":1793774512},"secondary":null}}}
    """.write(to: dir.appendingPathComponent("rollout-x.jsonl"), atomically: true, encoding: .utf8)
    let q = Quota.readCodex(home: home)
    check(q?.windows == [QuotaWindow(name: "7 ngày", usedPercent: 71, resetsAt: Date(timeIntervalSince1970: 1793774512))], "codex quota \(String(describing: q))")
    try? FileManager.default.removeItem(at: home)
}

// A quota window past its reset time shows as empty until the provider reports again.
do {
    let q = ProviderQuota(windows: [QuotaWindow(name: "5 giờ", usedPercent: 100, resetsAt: Date().addingTimeInterval(-60)),
                                    QuotaWindow(name: "7 ngày", usedPercent: 60, resetsAt: Date().addingTimeInterval(3600))], updated: Date())
    let r = q.resettingExpired()
    check(r.windows[0].usedPercent == 0 && r.windows[1].usedPercent == 60, "expired window reset, current one kept")
}

// Antigravity /usage panel scraping (text as captured from the TUI, ANSI codes included).
do {
    let raw = "\u{1b}[2K GEMINI MODELS\r\n  Models within this group: Gemini Flash\r\n  Weekly Limit Remaining\r\n    [\u{1b}[32m███░░\u{1b}[0m] 67.74%\r\nRefreshes in 116h 24m\r\n  Five Hour Limit Remaining\r\n[███] 97.27%\r\nRefreshes in 2h 19m\r\n74%\r\nCLAUDE AND GPT MODELS\r\n  Weekly Limit Remaining\r\n[██░] 49.49%\r\nRefreshes in 116h 45m\r\n  Five Hour Limit Remaining\r\n[███] 100.00%\r\n  Gemini 4 Argon Weekly Limit\r\n[███] 99.73%\r\nRefreshes in 166h 10m\r\n"
    let now = Date(timeIntervalSince1970: 0)
    let w = Quota.parseAntigravity(raw, now: now)
    check(w.map(\.name) == ["Gemini · tuần", "Gemini · 5 giờ", "Claude/GPT · tuần", "Claude/GPT · 5 giờ", "Gemini 4 Argon · tuần"], "agy names \(w.map(\.name))")
    check(abs(w[0].usedPercent - 32.26) < 0.01 && w[0].resetsAt == now.addingTimeInterval(116 * 3600 + 24 * 60), "agy gemini weekly")
    check(w[3].usedPercent == 0 && w[3].resetsAt == nil, "agy 5h full, no reset line")
    check(w[4].resetsAt == now.addingTimeInterval(166 * 3600 + 10 * 60), "agy argon reset")
}

// D2: Process ownership verification & orphan cleanup
do {
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("orph-\(shortId())")
    let paths = TeamPaths(workspace: ws)
    try paths.ensure()
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try sleeper.run()

    // 1. Legacy schema test: [String: Int32] -> do NOT signal sleeper, mark unverified
    try JSONEncoder().encode(["c_legacy": sleeper.processIdentifier]).write(to: paths.runningFile)
    let resLegacy = ProcessRunner.stopOrphans(paths)
    check(resLegacy.stopped == 0 && sleeper.isRunning, "legacy schema leaves process alone without blind signal")
    check(resLegacy.legacyChatIds.contains("c_legacy") && resLegacy.unverifiedChatIds.contains("c_legacy"), "legacy schema marks chat legacy and unverified")

    // 2. New schema with non-matching startTime / binary -> do NOT kill sleeper (recycled PID protection)
    let fakeRec = RunningProcessRecord(pid: sleeper.processIdentifier, startTimeSec: 100, startTimeUsec: 200, binary: "/usr/bin/other")
    try JSONEncoder().encode(["c_mismatch": fakeRec]).write(to: paths.runningFile)
    let resMismatch = ProcessRunner.stopOrphans(paths)
    check(resMismatch.stopped == 0 && sleeper.isRunning, "recycled/mismatched PID is NOT signaled")

    // 3. New schema with exact verified ownership -> kills sleeper safely
    let start = ProcessRunner.processStartTime(pid: sleeper.processIdentifier)!
    let realRec = RunningProcessRecord(pid: sleeper.processIdentifier, startTimeSec: start.0, startTimeUsec: start.1, binary: "/bin/sleep")
    try JSONEncoder().encode(["c_verified": realRec]).write(to: paths.runningFile)
    let resVerified = ProcessRunner.stopOrphans(paths)
    check(resVerified.stopped == 1 && !sleeper.isRunning, "verified owned process is stopped safely")
    check(!FileManager.default.fileExists(atPath: paths.runningFile.path), "running record cleared on exit")

    // 4. Symlink ownership (e.g. ~/.local/bin/claude -> /.../versions/...): verified and stopped
    let link = ws.appendingPathComponent("fakeclaude")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
    let symProc = Process()
    symProc.executableURL = link
    symProc.arguments = ["30"]
    try symProc.run()
    let symStart = ProcessRunner.processStartTime(pid: symProc.processIdentifier)!
    let symRec = RunningProcessRecord(pid: symProc.processIdentifier, startTimeSec: symStart.0, startTimeUsec: symStart.1, binary: link.path)
    try JSONEncoder().encode(["c_sym": symRec]).write(to: paths.runningFile)
    let resSym = ProcessRunner.stopOrphans(paths)
    check(resSym.stopped == 1 && !symProc.isRunning, "orphan launched via symlink is verified and stopped")

    // 5. Same pid + start time but a different path (script CLIs run under node/bash) -> still ours, stopped
    let pOther = Process()
    pOther.executableURL = URL(fileURLWithPath: "/bin/sleep")
    pOther.arguments = ["30"]
    try pOther.run()
    let otherStart = ProcessRunner.processStartTime(pid: pOther.processIdentifier)!
    let otherRec = RunningProcessRecord(pid: pOther.processIdentifier, startTimeSec: otherStart.0, startTimeUsec: otherStart.1, binary: "/usr/bin/unverified_other")
    try JSONEncoder().encode(["c_unverified": otherRec]).write(to: paths.runningFile)
    let resOther = ProcessRunner.stopOrphans(paths)
    check(resOther.stopped == 1 && resOther.unverifiedChatIds.isEmpty && !pOther.isRunning, "orphan under an interpreter (path differs, start time matches) is stopped")

    try? FileManager.default.removeItem(at: ws)
}

// D2: Inter-process lock via flock on .agentteam/lock & suspend holding lock
do {
    let wsLock = FileManager.default.temporaryDirectory.appendingPathComponent("locktest-\(shortId())")
    try FileManager.default.createDirectory(at: wsLock, withIntermediateDirectories: true)
    let o1 = try Orchestrator(workspace: wsLock) { _, _, _, _ in nil }

    var secondLocked = false
    do {
        _ = try Orchestrator(workspace: wsLock) { _, _, _, _ in nil }
    } catch OrchestratorError.workspaceLocked {
        secondLocked = true
    } catch {
        check(false, "unexpected error: \(error)")
    }
    check(secondLocked, "second Orchestrator on same workspace is blocked by flock")

    o1.releaseLock()
    let o3 = try? Orchestrator(workspace: wsLock) { _, _, _, _ in nil }
    check(o3 != nil, "subsequent Orchestrator acquires lock after release")
    o3?.releaseLock()

    // T1: Suspend with active runner holds lock until child terminates
    var childRunning = true
    let oT1 = try Orchestrator(workspace: wsLock) { _, _, _, _ in
        while childRunning {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return "exit 15: terminated"
    }
    let c = oT1.newChat(agentId: oT1.team.agents[0].id, title: "job")
    oT1.send("task", to: c)
    try? await Task.sleep(nanoseconds: 100_000_000)
    oT1.suspend()

    var secondAcquired = false
    do {
        _ = try Orchestrator(workspace: wsLock) { _, _, _, _ in nil }
        secondAcquired = true
    } catch OrchestratorError.workspaceLocked {
        secondAcquired = false
    } catch {}
    check(!secondAcquired, "T1: second instance blocked by lock while suspended runner child is still running")

    childRunning = false
    try? await Task.sleep(nanoseconds: 200_000_000)
    oT1.releaseLock()

    try? FileManager.default.removeItem(at: wsLock)
}

// R5 Arguments & Sandbox matrix
do {
    let r = TurnRequest(prompt: "x", profile: Profile(.codex, "gpt-6.1-sol", effort: "high"), sessionId: "t1", access: .write, canDispatch: false)
    let a = Provider.codex.arguments(r)
    check(a.prefix(2) == ["exec", "--json"] && a.suffix(3) == ["resume", "t1", "-"] && a.contains("model_reasoning_effort=high"), "codex args \(a)")
    check(a.contains("workspace-write"), "codex write access uses workspace-write")

    // Codex read-only without dispatch -> read-only sandbox
    let codexRO = Provider.codex.arguments(TurnRequest(prompt: "x", profile: Profile(.codex), sessionId: nil, access: .readOnly, canDispatch: false))
    check(codexRO.contains("read-only"), "codex read-only without dispatch uses sandbox read-only")

    // Codex read-only with dispatch -> workspace-write sandbox (agentteam needs write)
    let codexRODispatch = Provider.codex.arguments(TurnRequest(prompt: "x", profile: Profile(.codex), sessionId: nil, access: .readOnly, canDispatch: true))
    check(codexRODispatch.contains("workspace-write"), "codex read-only with dispatch uses workspace-write")

    let g = Provider.antigravity.arguments(TurnRequest(prompt: "hi", profile: Profile(.antigravity), sessionId: "g1", access: .readOnly))
    check(g[0...1] == ["-p", "hi"] && g.suffix(2) == ["--conversation", "g1"], "agy args \(g)")

    // Claude read-only without dispatch -> no Bash tool
    let clRO = Provider.claude.arguments(TurnRequest(prompt: "x", profile: Profile(.claude, "opus"), sessionId: nil, access: .readOnly, canDispatch: false))
    check(clRO.contains("--allowedTools") && !clRO.joined().contains("Bash"), "claude read-only without dispatch omits Bash tool")

    // Claude read-only with dispatch -> includes Bash agentteam
    let clRODispatch = Provider.claude.arguments(TurnRequest(prompt: "x", profile: Profile(.claude, "opus"), sessionId: nil, access: .readOnly, canDispatch: true))
    check(clRODispatch.contains("--allowedTools") && clRODispatch.joined().contains("Bash(agentteam"), "claude read-only with dispatch allows Bash agentteam")
}

// Schema backward compatibility & unreadable chat reporting (R3 / I/O)
do {
    let wsSchema = FileManager.default.temporaryDirectory.appendingPathComponent("schema-\(shortId())")
    let paths = TeamPaths(workspace: wsSchema)
    try paths.ensure()

    let oldChatJson = """
    {
        "id": "old1",
        "agentId": "a1",
        "title": "Old Chat",
        "status": "idle",
        "messages": [{"id": "\(UUID().uuidString)", "kind": "user", "text": "hello", "date": "2026-10-29T00:00:00Z"}],
        "pending": [],
        "inFlight": [],
        "trail": []
    }
    """
    try oldChatJson.data(using: .utf8)!.write(to: paths.chatFile("old1"))
    try "corrupt json data".data(using: .utf8)!.write(to: paths.chatFile("corrupt"))

    let oSchema = try Orchestrator(workspace: wsSchema) { _, _, _, _ in nil }
    check(oSchema.chats.contains(where: { $0.id == "old1" }), "old schema chat decodes cleanly")
    check(oSchema.chat("old1")?.receipts.isEmpty == true, "old schema defaults receipts to empty")
    check(oSchema.chat("old1")?.sessionAccess == nil, "old schema defaults sessionAccess to nil")
    check(oSchema.failedChatFiles.contains("corrupt.json"), "corrupt chat recorded in failedChatFiles")
    check(!oSchema.loadErrors.isEmpty, "corrupt chat has visible error message")

    // Health file check
    check(FileManager.default.fileExists(atPath: paths.healthFile.path), "health.json written on init")
    if let hData = try? Data(contentsOf: paths.healthFile),
       let health = try? jsonDecoder.decode(HealthRecord.self, from: hData) {
        check(health.loadedChats == 1 && health.failedChatFiles == 1, "health.json reports correct loaded and failed counts")
    } else {
        check(false, "health.json unreadable")
    }

    oSchema.releaseLock()
    try? FileManager.default.removeItem(at: wsSchema)
}

// R1: Handoff full text preservation (>12k input, >4k callback)
do {
    let longInput = String(repeating: "A", count: 15_000)
    var dummyChat = Chat(agentId: "w", title: "Test")
    dummyChat.messages.append(Message(.user, longInput))
    let pkg = Handoff.package(chat: dummyChat, role: nil, reason: "test", inputs: [Input(text: longInput, fromUser: true)], notes: nil, gitStatus: nil)
    check(pkg.contains(longInput), "input over 12k chars is NOT clipped in handoff package")
}


// Presets: recognised by shape, applying keeps chats attached, editing turns the team Custom.
do {
    var t = Team.starter()
    check(t.preset == .standard, "starter is the standard preset")
    let leadId = t.agents.first { $0.roleId == "lead" }!.id
    t.apply(TeamPreset.design.setup)
    check(t.preset == .design && t.agents.first { $0.roleId == "lead" }?.id == leadId, "design preset keeps the lead's agent id")
    t.agents[1].profile.model = "x"
    check(t.preset == nil, "edited preset becomes Custom")
    t.customSetup = t.setup
    check(t.customSetup?.sameShape(as: t.setup) == true && t.preset == nil, "custom setup saved per project")
    for p in TeamPreset.allCases {
        let s = p.setup
        check(Set(s.agents.map(\.roleId)).isSubset(of: Set(s.roles.map(\.id))) && s.roles.filter(\.canDispatch).count == 1, "\(p) preset is consistent")
    }
}

// Limits: Claude's "hit your 5-hour limit" counts, and its reset time is used instead of the fixed cooldown.
do {
    check(isLimitError("You've hit your 5-hour limit · resets 12:50am (Asia/Saigon)") && isLimitError("You've hit your weekly limit"),
          "Claude session/weekly limit messages detected")
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Saigon")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 23, minute: 22))!
    let r = limitResetDate("You've hit your 5-hour limit · resets 12:50am (Asia/Saigon)", now: now)
    check(r == cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 0, minute: 50)), "reset time rolls to the next day")
    let r2 = limitResetDate("weekly limit · resets Nov 2, 9am (Asia/Saigon)", now: now)
    check(r2 == cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9)), "reset with a date")
    check(limitResetDate("usage limit reached", now: now) == nil, "no time named")
}

// Chats opened with + take their title from the first message.
do {
    check(Chat.title(from: "Nghiên cứu chiến lược pullback TSI trên XAUUSD khung M15 và đánh giá tỷ lệ thắng\nchi tiết") == "Nghiên cứu chiến lược pullback TSI trên XAUUSD…",
          "long first line cut at a word")
    check(Chat.title(from: "Check giá BTC") == "Check giá BTC" && Chat.title(from: "\n") == Chat.untitled, "short/empty titles")
}

// Retired/unknown models: detected, skipped for that provider+model only; agy lists live models.
do {
    check(isModelError("The model `gpt-5-old` does not exist or you do not have access to it.")
          && isModelError("There's an issue with the selected model (claude-x). It may not exist or you may not have access to it.")
          && !isModelError("You've hit your 5-hour limit") && !isModelError("Added a model field to the schema"), "model errors detected")
    var t = Team.starter()
    t.badModels = [Profile(.antigravity, "gemini-3.8-flash-high").modelKey]
    check(t.agents.first { $0.roleId == "worker" }.flatMap(t.effectiveProfile) == Profile(.antigravity, "claude-sonnet-5-5-high"),
          "bad model skipped, same provider's other model still used")
    let st = Provider.antigravity.parseStatus(exit: 0, output: "Fetching available models...\ngemini-9-ultra-high\tGemini 9 Ultra (High)\ngemini-4-argon-high\tGemini 4 Argon (High)\n")
    check(st.ok == true && st.models == ["gemini-9-ultra-high", "gemini-4-argon-high"], "agy model list parsed")
}

// File links, attachments, network errors, sign-in status parsing.
do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentteam-links-\(shortId())")
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".agentteam/reports"), withIntermediateDirectories: true)
    try "x".write(to: root.appendingPathComponent(".agentteam/reports/bao cao.md"), atomically: true, encoding: .utf8)
    try "x".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    let md = linkifyPaths("Xem `.agentteam/reports/bao cao.md` và README.md:12, không phải e.g. hay github.com, [đã có](README.md).", root: root)
    check(md.contains("[.agentteam/reports/bao cao.md](.agentteam/reports/bao%20cao.md)"), "backticked path with space becomes a link")
    check(md.contains("[README.md:12](README.md%3A12)") && !md.contains("[github.com]") && md.contains("[đã có](README.md)"), "bare existing path linked, others untouched")
    check(resolveLocal(URL(string: "README.md:12")!, root: root)?.lastPathComponent == "README.md", "line suffix ignored when resolving")
    check(resolveLocal(URL(string: "https://example.com/a.md")!, root: root) == nil, "web links are not local files")
    check(Attachments.paths(in: "hi\n\n\(Attachments.marker)\n- a/b.png\n- c.pdf") == ["a/b.png", "c.pdf"], "attachment paths parsed")
    check(isNetworkError("TypeError: fetch failed (getaddrinfo ENOTFOUND api.openai.com)") && !isNetworkError("usage limit reached"), "network errors detected")
    check(isNetworkError(#"API error (attempt 1): request failed: Post "https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse": EOF"#),
          "agy dropped stream is retried")
    let guardDir = ProcessRunner.dispatcherGuardForChecks()
    let stub = Process()
    stub.executableURL = guardDir?.appendingPathComponent("codex")
    stub.standardError = FileHandle.nullDevice
    try? stub.run()
    stub.waitUntilExit()
    check(stub.terminationStatus == 64, "dispatchers cannot launch provider CLIs directly")
    check(Provider.claude.parseStatus(exit: 0, output: #"{"loggedIn": true, "email": "a@b.c"}"#) == AccountStatus(ok: true, detail: "a@b.c"), "claude status parsed")
    check(Provider.codex.parseStatus(exit: 1, output: "Not logged in").ok == false, "codex signed out")
    check(Provider.antigravity.parseStatus(exit: 0, output: "gemini-4-argon-high\tGemini").ok == true
          && Provider.antigravity.parseStatus(exit: 1, output: "error: not logged in").ok == false, "agy signed in/out")
    try? FileManager.default.removeItem(at: root)
}

// Hung command: the whole process tree is stopped.
do {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "sleep 60 & wait"]
    try p.run()
    usleep(300_000)
    let kids = ProcessRunner.descendantsForChecks(of: p.processIdentifier)
    ProcessRunner.terminateTree(p.processIdentifier)
    usleep(500_000)
    check(kids.count == 1 && kids.allSatisfy { kill($0, 0) != 0 } && !p.isRunning, "terminateTree stops the CLI and its child command")
}

// Output caps: an endless line or a flood of stderr stays bounded
do {
    var r = LineReader(maxLine: 8)
    var got: [String] = []
    for piece in ["o", "k\r\n01234", "56789abc\nnext\nta", "il"] { got += r.feed(Data(piece.utf8)) }
    if let l = r.finish() { got.append(l) }
    check(got == ["ok", "next", "tail"] && r.total == 27, "over-long stdout line is dropped, others kept")
    var t = TailBuffer(limit: 10)
    for _ in 0..<1000 { t.append(Data("0123456789".utf8)) }
    t.append(Data("END".utf8))
    check(t.text == "3456789END" && t.data.count <= 20, "stderr keeps only its tail")
}

// Orchestrator flow with a fake runner
let ws = FileManager.default.temporaryDirectory.appendingPathComponent("agentteam-check-\(shortId())")
try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)

@MainActor func scenario() async throws {
    var prompts: [(Provider, String)] = []
    let o = try Orchestrator(workspace: ws) { chatId, req, _, emit in
        prompts.append((req.profile.provider, req.prompt))
        if req.profile.provider == .claude && req.prompt.contains("LIMIT-ME") {
            emit(.failure("Claude AI usage limit reached"))
            return nil
        }
        emit(.session("sess-\(chatId)"))
        emit(.progress("đang làm"))
        emit(.final("xong: \(req.prompt.suffix(20))"))
        return nil
    }
    o.gitStatus = { _ in nil }
    o.team = Team.starter()  // independent of a template the user saved
    let li = o.team.agents.firstIndex { $0.roleId == "lead" }!
    o.team.agents[li].profile = Profile(.claude, "opus")
    let lead = o.team.agents[li]
    let worker = o.team.agents.first { $0.roleId == "worker" }!
    let leadChat = o.newChat(agentId: lead.id, title: "Main")

    func settle() async { for _ in 0..<200 where o.chats.contains(where: { [.running, .queued].contains($0.status) }) { try? await Task.sleep(nanoseconds: 5_000_000) } }

    o.send("Sửa nút Lưu", to: leadChat)
    await settle()
    check(prompts.first?.1.contains("HỢP ĐỒNG VAI TRÒ") == true && prompts.first?.1.contains("agentteam dispatch") == true, "lead gets preamble with dispatch help")

    // R3: Dispatch with atomic receipt and replay testing
    let reqId = "req-test-\(shortId())"
    let req = DispatchRequest(id: reqId, from: leadChat, to: "worker", title: "Fix Save", tab: nil, body: "Sửa nút Lưu")
    let ack = o.handle(req)
    check(ack.disposition != "rejected" && ack.chatId != nil, "dispatch accepted \(ack)")
    let wChatId = ack.chatId!

    // Verify receipt was committed to disk chat
    let wChat = o.chat(wChatId)!
    check(wChat.receipts.contains(where: { $0.id == reqId }), "dispatch receipt recorded in chat")

    // Replay identical dispatch: must return identical ACK without duplicating task
    let preReplayCount = o.chat(wChatId)!.messages.count
    let ackReplay = o.handle(req)
    check(ackReplay.disposition == ack.disposition && ackReplay.chatId == wChatId, "replay identical request returns existing ACK")
    check(o.chat(wChatId)!.messages.count == preReplayCount, "replay did not duplicate task in chat")

    // ID conflict on different body: rejected
    let confReq = DispatchRequest(id: reqId, from: leadChat, to: "worker", title: "Fix Save", tab: nil, body: "DIFFERENT CONTENT")
    let ackConflict = o.handle(confReq)
    check(ackConflict.disposition == "rejected" && ackConflict.reason?.contains("Xung đột") == true, "conflict on different fingerprint rejected")

    // Replay original request after conflict still returns valid original ACK, and disk ACK was NOT overwritten
    let ackAfterConflict = o.handle(req)
    check(ackAfterConflict.disposition == ack.disposition && ackAfterConflict.chatId == wChatId, "original request replay after conflict returns valid original ACK")
    let ackDisk = (try? JSONDecoder().decode(DispatchAck.self, from: Data(contentsOf: o.paths.ackFile(reqId))))?.disposition
    check(ackDisk == ack.disposition, "conflict did not overwrite original ACK on disk")

    // R3a/R3b: Inbox-level tests
    func putInbox(_ r: DispatchRequest) throws { try JSONEncoder().encode(r).write(to: o.paths.inbox.appendingPathComponent("\(r.id).json")) }
    func ackDiskOf(_ id: String) -> DispatchAck? { (try? Data(contentsOf: o.paths.ackFile(id))).flatMap { try? JSONDecoder().decode(DispatchAck.self, from: $0) } }

    // R3a legit then conflict through inbox
    let i1Id = "inbox-i1-\(shortId())"
    try putInbox(DispatchRequest(id: i1Id, from: leadChat, to: "worker", title: "t", tab: nil, body: "A"))
    o.processInbox()
    let origAck = ackDiskOf(i1Id)
    try putInbox(DispatchRequest(id: i1Id, from: leadChat, to: "worker", title: "t", tab: nil, body: "OTHER"))
    o.processInbox()
    let afterAck = ackDiskOf(i1Id)
    check(afterAck?.disposition == origAck?.disposition && afterAck?.chatId == origAck?.chatId && origAck?.disposition != "rejected", "R3a inbox conflict does not overwrite original ACK")

    // R3b receipt present, ACK missing, conflict first, then original
    let i2Id = "inbox-i2-\(shortId())"
    try putInbox(DispatchRequest(id: i2Id, from: leadChat, to: "worker", title: "t", tab: nil, body: "A2"))
    o.processInbox()
    try? FileManager.default.removeItem(at: o.paths.ackFile(i2Id))
    try putInbox(DispatchRequest(id: i2Id, from: leadChat, to: "worker", title: "t", tab: nil, body: "CONFLICT"))
    o.processInbox()
    try putInbox(DispatchRequest(id: i2Id, from: leadChat, to: "worker", title: "t", tab: nil, body: "A2"))
    o.processInbox()
    let finAck = ackDiskOf(i2Id)
    check(finAck?.disposition != "rejected" && finAck?.chatId != nil, "R3b receipt w/o ACK: conflict must not poison; original replay gets accepted ACK")

    // Transient I/O commit error does not persist rejected ACK; retry succeeds
    chmod(o.paths.chats.path, 0o500)
    let ioReqId = "req-io-\(shortId())"
    let ioReq = DispatchRequest(id: ioReqId, from: leadChat, to: "worker", title: "IO Test", tab: nil, body: "Transient IO")
    let ioAck1 = o.handle(ioReq)
    check(ioAck1.disposition == "rejected" && ioAck1.reason?.contains("Lỗi I/O") == true, "transient commit error rejected")
    check(!FileManager.default.fileExists(atPath: o.paths.ackFile(ioReqId).path), "transient I/O error did not persist rejected ACK to disk")
    check(o.lastIOError != nil, "lastIOError recorded on I/O failure")
    chmod(o.paths.chats.path, 0o700)
    let ioAck2 = o.handle(ioReq)
    check(ioAck2.disposition != "rejected", "retry same id after I/O recovery succeeds")

    await settle()
    check(o.chat(wChatId)!.agentId == worker.id && o.chat(wChatId)!.status == .done, "worker done")
    check(o.chat(leadChat)!.messages.contains { $0.kind == .callback && $0.text.contains("Kết quả từ Worker") && $0.text.contains("profile:") }, "callback in lead chat with profile")
    check(prompts.last?.1.contains("HỢP ĐỒNG VAI TRÒ") == false, "lead resumed without preamble (token saving)")

    // Deleted chat after ACK: returns inconsistency rejection
    let delReq = DispatchRequest(id: "req-del", from: leadChat, to: "worker", title: "To Del", tab: nil, body: "Delete soon")
    let ackToDel = o.handle(delReq)
    check(ackToDel.chatId != nil, "dispatch for delete test")
    o.deleteChat(ackToDel.chatId!)
    let ackAfterDel = o.handle(delReq)
    check(ackAfterDel.disposition == "rejected" && ackAfterDel.reason?.contains("Bất nhất") == true, "deleted chat after ACK reports inconsistency")

    // Workers cannot dispatch; unknown targets are rejected.
    check(o.handle(DispatchRequest(from: wChatId, to: "lead", title: "x", tab: nil, body: "x")).disposition == "rejected", "worker cannot dispatch")
    check(o.handle(DispatchRequest(from: leadChat, to: "nobody", title: "x", tab: nil, body: "x")).disposition == "rejected", "unknown target")

    // Limit on Claude → auto failover to Codex with a handoff package; provider marked limited.
    o.send("LIMIT-ME tiếp tục", to: leadChat)
    await settle()
    check(o.team.limitedProviders.contains(.claude), "claude marked limited")
    let last = prompts.last!
    check(last.0 == .antigravity && last.1.isEmpty == false && last.1.contains("BÀN GIAO CÔNG VIỆC") && last.1.contains("LIMIT-ME"), "failover prompt carries handoff")
    check(o.chat(leadChat)!.status == .done, "lead finished on fallback")

    // Limits are released after the cooldown and the provider is used again.
    o.releaseExpiredLimits(now: Date().addingTimeInterval(Double(o.team.limitCooldownMinutes * 60 + 1)))
    check(!o.team.limitedProviders.contains(.claude), "limit released after cooldown")
    check(o.totalTokens == 0, "fake runner reports no usage")

    // Manual transfer moves replyTo and work into the new chat.
    let w2 = o.newChat(agentId: worker.id, title: "Tiếp quản")
    o.transfer(from: wChatId, to: w2)
    await settle()
    check(o.chat(w2)!.messages.first?.kind == .handoff && o.chat(w2)!.replyTo == leadChat, "manual transfer")

    // Replace provider in one click.
    o.replaceProvider(.claude, with: Profile(.antigravity, "gemini-3.8-flash-high"))
    check(!o.team.agents.contains { $0.profile.provider == .claude }, "replace provider")

    // R1: Prompt exceeding Antigravity argv limit is blocked before inFlight and kept in pending
    o.replaceProvider(.codex, with: Profile(.antigravity, "gemini-3.8-flash-high"))
    let hugePrompt = String(repeating: "Z", count: Provider.maxAntigravityPromptBytes + 500)
    o.send(hugePrompt, to: w2)
    await settle()
    check(o.chat(w2)?.status == .failed, "huge prompt exceeds agy argv limit and fails")
    check(o.chat(w2)?.pending.first?.text == hugePrompt, "overflowed prompt stays in pending")
    check(o.chat(w2)!.messages.contains { $0.kind == .system && $0.text.contains("ngưỡng argv") }, "system message explains argv overflow")

    // Clear pending for w2 before restart test
    o.deleteChat(w2)

    // Restart recovery: release lock from running instance to simulate termination before reload
    let w3 = o.newChat(agentId: worker.id, title: "Dở việc")
    o.team.maxConcurrent = 0
    o.send("việc dở", to: w3)
    o.releaseLock()
    let reloaded = try Orchestrator(workspace: ws) { _, _, _, _ in nil }
    check(reloaded.chat(w3)?.status == .queued && reloaded.chat(w3)?.pending.isEmpty == false, "restart keeps queued work")

    // D3 backoff progression: 10m -> 20m -> 40m -> 60m
    check(reloaded.agyBackoffMinutes == 10, "initial backoff is 10 minutes")
    reloaded.agyFailCount = 1
    check(reloaded.agyBackoffMinutes == 10, "1st fail backoff is 10 minutes")
    reloaded.agyFailCount = 2
    check(reloaded.agyBackoffMinutes == 20, "2nd fail backoff is 20 minutes")
    reloaded.agyFailCount = 3
    check(reloaded.agyBackoffMinutes == 40, "3rd fail backoff is 40 minutes")
    reloaded.agyFailCount = 4
    check(reloaded.agyBackoffMinutes == 60, "4th fail backoff is 60 minutes")
    reloaded.agyFailCount = 0

    // QuotaStatus .error after failure
    let fakeAgy = ws.appendingPathComponent("fake_agy.sh")
    try "#!/bin/sh\nexit 1\n".write(to: fakeAgy, atomically: true, encoding: .utf8)
    chmod(fakeAgy.path, 0o755)
    reloaded.antigravityBinary = { fakeAgy.path }
    reloaded.refreshAntigravityQuota(force: true)
    for _ in 0..<50 where Orchestrator.antigravityProbeRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
    let st = reloaded.quotaStatus(for: .antigravity)
    if case .error = st {
        check(true, "quotaStatus is .error after probe failure")
    } else {
        check(false, "quotaStatus expected .error but got \(st)")
    }

    reloaded.releaseLock()
}

// Suspending a workspace (switch/close) requeues running work instead of losing it.
@MainActor func suspendScenario() async throws {
    let ws2 = ws.appendingPathComponent("b")
    try FileManager.default.createDirectory(at: ws2, withIntermediateDirectories: true)
    var started = false
    let o = try Orchestrator(workspace: ws2) { _, _, _, _ in
        started = true
        try? await Task.sleep(nanoseconds: 100_000_000)
        return "exit 15: terminated"
    }
    let c = o.newChat(agentId: o.team.agents[0].id, title: "dở")
    o.send("việc dài", to: c)
    for _ in 0..<50 where !started { try? await Task.sleep(nanoseconds: 2_000_000) }
    o.suspend()
    for _ in 0..<100 where o.chat(c)?.status == .running { try? await Task.sleep(nanoseconds: 5_000_000) }
    check(o.chat(c)?.status == .queued && o.chat(c)?.pending.first?.text == "việc dài", "suspend requeues running turn")
    check(!o.chat(c)!.messages.contains { $0.kind == .system }, "suspend adds no error message")
    o.releaseLock()
}

// R1: First turn limit error triggers handoff package on fallback
@MainActor func firstTurnLimitScenario() async throws {
    let wsFirst = ws.appendingPathComponent("firstlim")
    try FileManager.default.createDirectory(at: wsFirst, withIntermediateDirectories: true)
    var promptsSeen: [String] = []
    let o = try Orchestrator(workspace: wsFirst) { _, req, _, emit in
        promptsSeen.append(req.prompt)
        if req.profile.provider == .claude {
            emit(.failure("Claude AI usage limit reached"))
            return nil
        }
        emit(.session("sess-fallback"))
        emit(.final("Done on fallback"))
        return nil
    }
    o.gitStatus = { _ in nil }
    o.team = Team.starter()
    // Make sure planner has claude profile
    let plannerAgent = o.team.agents.first { $0.roleId == "planner" }!
    let pChat = o.newChat(agentId: plannerAgent.id, title: "First Turn Limit Chat")

    func settle() async { for _ in 0..<200 where o.chats.contains(where: { [.running, .queued].contains($0.status) }) { try? await Task.sleep(nanoseconds: 5_000_000) } }

    o.send("First turn prompt", to: pChat)
    await settle()

    check(o.chat(pChat)?.status == .done, "chat finished on fallback provider after first turn limit")
    check(promptsSeen.count >= 2, "claude was called then fallback was called")
    check(promptsSeen.last?.contains("BÀN GIAO CÔNG VIỆC") == true, "first turn limit triggered handoff package")
    o.releaseLock()
}

// R5: Session resume requires exact match of (profile, access, canDispatch)
@MainActor func resumeTupleScenario() async throws {
    let wsResume = ws.appendingPathComponent("resume-tuple")
    try FileManager.default.createDirectory(at: wsResume, withIntermediateDirectories: true)
    var sessionPrompts: [String] = []
    var requestedSessions: [String?] = []
    let o = try Orchestrator(workspace: wsResume) { _, req, _, emit in
        sessionPrompts.append(req.prompt)
        requestedSessions.append(req.sessionId)
        emit(.session("sess-123"))
        emit(.final("Response"))
        return nil
    }
    o.gitStatus = { _ in nil }
    o.team = Team.starter()
    let lead = o.team.agents.first { $0.roleId == "lead" }!
    let c = o.newChat(agentId: lead.id, title: "Resume Test")

    func settle() async { for _ in 0..<200 where o.chats.contains(where: { [.running, .queued].contains($0.status) }) { try? await Task.sleep(nanoseconds: 5_000_000) } }

    // Turn 1: Fresh turn, no session yet
    o.send("Turn 1", to: c)
    await settle()
    check(requestedSessions.first! == nil, "first turn has no sessionId")
    check(o.chat(c)?.sessionId == "sess-123", "session recorded")
    check(o.chat(c)?.sessionAccess == .write, "sessionAccess recorded")
    check(o.chat(c)?.sessionCanDispatch == true, "sessionCanDispatch recorded")

    // Turn 2: Same profile, access, canDispatch -> Resumed!
    o.send("Turn 2", to: c)
    await settle()
    check(requestedSessions.last! == "sess-123", "matching tuple resumes session")

    // Turn 3: Modify role access (simulate privilege change) -> tuple mismatch -> fresh session with handoff package!
    let leadRoleIdx = o.team.roles.firstIndex { $0.id == "lead" }!
    o.team.roles[leadRoleIdx].access = .readOnly
    o.send("Turn 3", to: c)
    await settle()
    check(requestedSessions.last! == nil, "access change prevented session resume")
    check(sessionPrompts.last?.contains("BÀN GIAO CÔNG VIỆC") == true, "access change generated handoff package")

    o.releaseLock()
}

// Install-check hook keeps pump, polling and probe disabled
@MainActor func installCheckScenario() async throws {
    let wsCheck = ws.appendingPathComponent("install-check")
    try FileManager.default.createDirectory(at: wsCheck, withIntermediateDirectories: true)
    var ranTurn = false
    let o = try Orchestrator(workspace: wsCheck, isInstallCheck: true) { _, _, _, _ in
        ranTurn = true
        return nil
    }
    let c = o.newChat(agentId: o.team.agents[0].id, title: "Test")
    o.send("Should not run during install check", to: c)
    o.pump()
    try? await Task.sleep(nanoseconds: 50_000_000)
    check(!ranTurn, "pump is disabled during install check")
    check(o.chat(c)?.status == .queued, "turn remains queued during install check")
    check(FileManager.default.fileExists(atPath: o.paths.healthFile.path), "health.json is generated during install check")
    o.releaseLock()
}


// Watchdog: a silent turn is stopped, retried once with a warning, then failed.
@MainActor func stallScenario() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentteam-stall-\(shortId())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var prompts: [String] = []
    var cancelled = false
    let o = try Orchestrator(workspace: dir) { _, req, _, emit in
        prompts.append(req.prompt)
        cancelled = false
        emit(.progress("run_command FaultProbe"))
        for _ in 0..<400 where !cancelled { try? await Task.sleep(nanoseconds: 5_000_000) }
        return "exit 15"
    }
    o.cancelTurn = { _ in cancelled = true }
    o.gitStatus = { _ in nil }
    let worker = o.team.agents.first { $0.roleId == "worker" }!
    o.team.agents[o.team.agents.firstIndex { $0.id == worker.id }!].profile = Profile(.claude, "sonnet")
    let c = o.newChat(agentId: worker.id, title: "w")
    o.send("chạy test", to: c)
    for _ in 0..<100 where prompts.count < 1 { try? await Task.sleep(nanoseconds: 5_000_000) }
    o.checkStalls(now: Date().addingTimeInterval(3600))
    for _ in 0..<200 where prompts.count < 2 { try? await Task.sleep(nanoseconds: 5_000_000) }
    check(prompts.count == 2 && prompts[1].contains("Lượt trước bị dừng") && prompts[1].contains("run_command FaultProbe"), "stalled turn retried once with the hung step named")
    o.checkStalls(now: Date().addingTimeInterval(3600))
    for _ in 0..<200 where o.chat(c)?.status != .failed { try? await Task.sleep(nanoseconds: 5_000_000) }
    check(o.chat(c)?.status == .failed && prompts.count == 2, "second stall fails the chat instead of looping")
    o.stopInboxPolling()
    try? FileManager.default.removeItem(at: dir)
}

// Network drop: the turn waits and retries instead of failing the work.
@MainActor func networkScenario() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentteam-net-\(shortId())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var runs = 0
    let o = try Orchestrator(workspace: dir) { _, _, _, emit in
        runs += 1
        if runs == 1 { return "exit 1: TypeError: fetch failed (getaddrinfo ENOTFOUND api.openai.com)" }
        emit(.final("ok"))
        return nil
    }
    o.gitStatus = { _ in nil }
    let worker = o.team.agents.first { $0.roleId == "worker" }!
    o.team.agents[o.team.agents.firstIndex { $0.id == worker.id }!].profile = Profile(.claude, "sonnet")
    let c = o.newChat(agentId: worker.id, title: "w")
    o.send("việc", to: c)
    for _ in 0..<100 where o.retryAt[c] == nil { try? await Task.sleep(nanoseconds: 5_000_000) }
    check(o.retryAt[c] != nil && o.chat(c)?.status == .queued && runs == 1 && o.chat(c)?.pending.count == 1, "network failure waits with work kept")
    o.retryNow(c)
    for _ in 0..<200 where o.chat(c)?.status != .done { try? await Task.sleep(nanoseconds: 5_000_000) }
    check(o.chat(c)?.status == .done && runs == 2, "retry after network is back finishes the work")
    try? FileManager.default.removeItem(at: dir)
}

// Relays: Planner ↔ Critic and Worker → Testing run without the dispatcher; it only gets the outcome.
@MainActor func relayScenario() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentteam-relay-\(shortId())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var leadTurns = 0, critic = 0, testing = 0
    let o = try Orchestrator(workspace: dir) { _, req, _, emit in
        let p = req.prompt
        if p.contains("[Phản biện tự động") {
            critic += 1
            emit(.final(critic == 1 ? "Phản bác lớn: thiếu rollback." : "KHÔNG CÒN PHẢN BÁC LỚN"))
        } else if p.contains("[Nghiệm thu tự động") {
            testing += 1
            emit(.final("Tiêu chí 1: KHÔNG ĐẠT\nKẾT LUẬN: KHÔNG ĐẠT"))
        } else if p.contains("HỢP ĐỒNG VAI TRÒ") && p.contains("agentteam dispatch") || p.contains("[Kết quả từ") {
            leadTurns += 1
            emit(.final("lead ok"))
        } else {
            emit(.final("bản làm \(p.count)"))
        }
        return nil
    }
    o.gitStatus = { _ in nil }
    for i in o.team.agents.indices { o.team.agents[i].profile = Profile(.claude, "sonnet") }
    let lead = o.team.agents.first { $0.roleId == "lead" }!
    let leadChat = o.newChat(agentId: lead.id, title: "L")
    func settle() async { for _ in 0..<400 where o.chats.contains(where: { [.running, .queued].contains($0.status) }) { try? await Task.sleep(nanoseconds: 5_000_000) } }
    o.send("bắt đầu", to: leadChat)
    await settle()
    leadTurns = 0

    _ = o.handle(DispatchRequest(from: leadChat, to: "planner", title: "PA", tab: nil, body: "Đề xuất cache", reviewer: "critic", mode: .debate, rounds: 3))
    await settle()
    let back = o.chat(leadChat)!.messages.last { $0.kind == .callback }?.text ?? ""
    check(critic == 2 && leadTurns == 1 && back.contains("chốt sau 2 vòng") && back.contains("KHÔNG CÒN PHẢN BÁC LỚN"),
          "debate loops planner↔critic without the lead and reports once")
    let planner = o.chats.first { $0.title == "PA" }!
    check(planner.relay == nil && o.chats.filter { $0.title.hasPrefix("Phản biện:") }.count == 1, "debate reuses one critic chat and ends")

    o.send("tiếp", to: leadChat)  // a new lead turn, as in real use
    await settle()
    leadTurns = 0
    _ = o.handle(DispatchRequest(from: leadChat, to: "worker", title: "W", tab: nil, body: "Sửa nút", reviewer: "testing", mode: .verify, rounds: 2))
    await settle()
    let verdict = o.chat(leadChat)!.messages.last { $0.kind == .callback }?.text ?? ""
    check(testing == 2 && leadTurns == 1 && verdict.contains("KHÔNG ĐẠT sau 2 vòng"), "verify stops after max rounds and reports the failure once")
    check(Relay.passed("…\nKẾT LUẬN: ĐẠT", mode: .verify) && !Relay.passed("KẾT LUẬN: KHÔNG ĐẠT", mode: .verify)
          && Relay.passed("Mọi tiêu chí ĐẠT", mode: .verify), "verify verdict parsing")
    try? FileManager.default.removeItem(at: dir)
}

// A known reset time holds the provider until then, not just the cooldown.
@MainActor func limitUntilScenario() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentteam-until-\(shortId())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let o = try Orchestrator(workspace: dir) { _, _, _, _ in "exit 1: You've hit your 5-hour limit · resets 11pm (Asia/Saigon)" }
    o.gitStatus = { _ in nil }
    o.team.autoFailover = false
    let t = o.team.agents.first { $0.roleId == "testing" }!
    o.team.agents[o.team.agents.firstIndex { $0.id == t.id }!].profile = Profile(.claude, "sonnet")
    let c = o.newChat(agentId: t.id, title: "t")
    o.send("viết test", to: c)
    for _ in 0..<200 where o.chat(c)?.status != .limited { try? await Task.sleep(nanoseconds: 5_000_000) }
    let until = o.team.limitedUntil?["claude"]
    check(o.chat(c)?.status == .limited && o.chat(c)?.pending.count == 1 && until != nil, "limit keeps the work and records the reset time")
    o.releaseExpiredLimits(now: Date().addingTimeInterval(TimeInterval(o.team.limitCooldownMinutes * 60 + 1)))
    if let until, until > Date().addingTimeInterval(TimeInterval(o.team.limitCooldownMinutes * 60 + 1)) {
        check(o.team.limitedProviders.contains(.claude), "not retried at the cooldown when the reset is later")
    }
    o.releaseExpiredLimits(now: (until ?? Date()).addingTimeInterval(1))
    check(!o.team.limitedProviders.contains(.claude), "retried once the reset time passes")
    o.stop(c)
    try? FileManager.default.removeItem(at: dir)
}

// A retired model fails over to the next profile and keeps the work.
@MainActor func badModelScenario() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentteam-model-\(shortId())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var used: [String] = []
    let o = try Orchestrator(workspace: dir) { _, req, _, emit in
        used.append(req.profile.model)
        if req.profile.model == "gone-model" { return "exit 1: The model `gone-model` does not exist or you do not have access to it." }
        emit(.final("ok"))
        return nil
    }
    o.gitStatus = { _ in nil }
    let w = o.team.agents.first { $0.roleId == "worker" }!
    o.team.agents[o.team.agents.firstIndex { $0.id == w.id }!].profile = Profile(.antigravity, "gone-model")
    let c = o.newChat(agentId: w.id, title: "w")
    o.send("làm", to: c)
    for _ in 0..<200 where o.chat(c)?.status != .done { try? await Task.sleep(nanoseconds: 5_000_000) }
    check(o.chat(c)?.status == .done && used == ["gone-model", "claude-sonnet-5-5-high"] && o.team.badModels?.count == 1,
          "retired model fails over to the next fallback")
    try? FileManager.default.removeItem(at: dir)
}

// Real pipes: a normal turn still parses, a flooding CLI is stopped instead of filling RAM
@MainActor func outputCapScenario() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentteam-out-\(shortId())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    func script(_ name: String, _ body: String) throws -> String {
        let f = dir.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body + "\n").write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        return f.path
    }
    let ok = try script("ok", #"cat >/dev/null; echo '{"type":"result","subtype":"success","result":"xong","session_id":"s1"}'; yes err | head -c 3000000 >&2"#)
    let flood = try script("flood", "cat >/dev/null; yes 'loop line'")
    let runner = ProcessRunner(helperDir: nil)
    let req = TurnRequest(prompt: "hi", profile: Profile(.claude, "sonnet"), sessionId: nil, access: .readOnly)
    var final: String?
    let e1 = await runner.run(chatId: "a", request: req, cwd: dir, binaryPath: ok) { if case .final(let t) = $0 { final = t } }
    check(e1 == nil && final == "xong", "real CLI output still parses with capped readers")
    let started = Date()
    let e2 = await runner.run(chatId: "b", request: req, cwd: dir, binaryPath: flood) { _ in }
    check(e2?.contains("MB") == true && Date().timeIntervalSince(started) < 60, "flooding CLI is stopped at the output cap")
    try? FileManager.default.removeItem(at: dir)
}

try await scenario()
try await outputCapScenario()
try await badModelScenario()
try await limitUntilScenario()
try await relayScenario()
try await stallScenario()
try await networkScenario()
try await suspendScenario()
try await firstTurnLimitScenario()
try await resumeTupleScenario()
try await installCheckScenario()
try? FileManager.default.removeItem(at: ws)

print(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)