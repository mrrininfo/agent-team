import AgentTeamCore
import Foundation

// Assert-based self-check (no XCTest with Command Line Tools). Run: swift run AgentTeamChecks
var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}

// Parsers
do {
    var p = OutputParser(.claude)
    check(p.feed(#"{"type":"system","subtype":"init","session_id":"s1"}"#) == [.session("s1")], "claude init")
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

    check(isLimitError("You've hit your usage limit.") && isLimitError("RESOURCE_EXHAUSTED") && !isLimitError("file not found"), "limit detection")
}

// Built-in template: Planner and Critic on different providers, also after Claude is switched off.
do {
    var t = Team.starter()
    check(Set(t.roles.map(\.id)) == ["lead", "planner", "critic", "worker", "testing"], "template roles")
    func provider(_ role: String) -> Provider? { t.agents.first { $0.roleId == role }.flatMap(t.effectiveProfile)?.provider }
    check(provider("planner") != provider("critic"), "planner/critic differ")
    t.disabledProviders = [.claude]
    let p = t.agents.first { $0.roleId == "planner" }.flatMap(t.effectiveProfile)
    check(p?.provider == .antigravity && p?.model.hasPrefix("claude") == true, "planner keeps a Claude model via Antigravity")
    check(provider("planner") != provider("critic"), "planner/critic still differ without Claude")
}

// Older team.json without newer optional fields still decodes (no reset to template).
do {
    var json = try JSONSerialization.jsonObject(with: jsonEncoder.encode(Team.starter())) as! [String: Any]
    json.removeValue(forKey: "debateRounds")
    check((try? jsonDecoder.decode(Team.self, from: JSONSerialization.data(withJSONObject: json))) != nil, "old team.json decodes")
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

// Orphan cleanup only touches our own provider CLIs and clears the record.
do {
    let ws = FileManager.default.temporaryDirectory.appendingPathComponent("orph-\(shortId())")
    let paths = TeamPaths(workspace: ws)
    try paths.ensure()
    let sleeper = Process()
    sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
    sleeper.arguments = ["30"]
    try sleeper.run()
    try JSONEncoder().encode(["c1": sleeper.processIdentifier]).write(to: paths.runningFile)
    check(ProcessRunner.stopOrphans(paths) == 0 && sleeper.isRunning, "non-provider pid left alone")
    check(!FileManager.default.fileExists(atPath: paths.runningFile.path), "running record cleared")
    sleeper.terminate()
    try? FileManager.default.removeItem(at: ws)
}

// Arguments
do {
    let r = TurnRequest(prompt: "x", profile: Profile(.codex, "gpt-6.1-sol", effort: "high"), sessionId: "t1", access: .write)
    let a = Provider.codex.arguments(r)
    check(a.prefix(2) == ["exec", "--json"] && a.suffix(3) == ["resume", "t1", "-"] && a.contains("model_reasoning_effort=high"), "codex args \(a)")
    let g = Provider.antigravity.arguments(TurnRequest(prompt: "hi", profile: Profile(.antigravity), sessionId: "g1", access: .readOnly))
    check(g[0...1] == ["-p", "hi"] && g.suffix(2) == ["--conversation", "g1"], "agy args \(g)")
    let cl = Provider.claude.arguments(TurnRequest(prompt: "x", profile: Profile(.claude, "opus"), sessionId: nil, access: .readOnly))
    check(cl.contains("--allowedTools") && !cl.contains("--dangerously-skip-permissions"), "claude read-only args")
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

    // Lead dispatches to worker; result must come back to the lead chat.
    let ack = o.handle(DispatchRequest(from: leadChat, to: "worker", title: "Fix Save", tab: nil, body: "Sửa nút Lưu"))
    check(ack.disposition != "rejected" && ack.chatId != nil, "dispatch accepted \(ack)")
    await settle()
    let wChat = o.chat(ack.chatId!)!
    check(wChat.agentId == worker.id && wChat.status == .done, "worker done")
    check(o.chat(leadChat)!.messages.contains { $0.kind == .callback && $0.text.contains("Kết quả từ Worker") }, "callback in lead chat")
    check(prompts.last?.1.contains("HỢP ĐỒNG VAI TRÒ") == false, "lead resumed without preamble (token saving)")

    // Workers cannot dispatch; unknown targets are rejected.
    check(o.handle(DispatchRequest(from: wChat.id, to: "lead", title: "x", tab: nil, body: "x")).disposition == "rejected", "worker cannot dispatch")
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
    o.transfer(from: wChat.id, to: w2)
    await settle()
    check(o.chat(w2)!.messages.first?.kind == .handoff && o.chat(w2)!.replyTo == leadChat, "manual transfer")

    // Replace provider in one click.
    o.replaceProvider(.claude, with: Profile(.antigravity, "gemini-3.8-flash-high"))
    check(!o.team.agents.contains { $0.profile.provider == .claude }, "replace provider")

    // Restart recovery: a chat left running is re-queued.
    o.team.maxConcurrent = 0
    o.send("việc dở", to: w2)
    let reloaded = try Orchestrator(workspace: ws) { _, _, _, _ in nil }
    check(reloaded.chat(w2)?.status == .queued && reloaded.chat(w2)?.pending.isEmpty == false, "restart keeps queued work")
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
}

try await scenario()
try await suspendScenario()
try? FileManager.default.removeItem(at: ws)
print(failures == 0 ? "All checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
