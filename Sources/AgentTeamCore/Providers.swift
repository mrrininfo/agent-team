import Foundation

public struct TurnRequest: Sendable {
    public var prompt: String
    public var profile: Profile
    public var sessionId: String?
    public var access: Access
    public var canDispatch: Bool

    public init(prompt: String, profile: Profile, sessionId: String?, access: Access, canDispatch: Bool = false) {
        self.prompt = prompt
        self.profile = profile
        self.sessionId = sessionId
        self.access = access
        self.canDispatch = canDispatch
    }
}

public enum RunEvent: Equatable, Sendable {
    case session(String)
    case progress(String)
    case final(String)
    case failure(String)
    /// Uncached input + output tokens of one turn.
    case usage(Int)
    /// Subscription limit windows reported by the CLI.
    case quota([QuotaWindow])
    /// Exact model metadata reported by the CLI runtime.
    case modelMetadata(String)
}

private func int(_ d: [String: Any]?, _ k: String) -> Int { (d?[k] as? NSNumber)?.intValue ?? 0 }

extension Provider {
    /// claude and codex read the prompt from stdin (no argv size limit); agy takes it as the -p value.
    public var promptViaStdin: Bool { self != .antigravity }

    /// Conservative prompt limit in bytes when passing via argv (-p) on Antigravity;
    /// Claude and Codex use stdin and do not have this restriction.
    public static let maxAntigravityPromptBytes = 131_072 // shortcut: conservative argv limit for Antigravity until R4b measurement

    public func arguments(_ r: TurnRequest) -> [String] {
        let p = r.profile
        switch self {
        case .claude:
            var a = ["-p", "--output-format", "stream-json", "--verbose"]
            if !p.model.isEmpty { a += ["--model", p.model] }
            if let s = r.sessionId { a += ["--resume", s] }
            if r.access == .write {
                a += ["--dangerously-skip-permissions"]
            } else {
                let tools = r.canDispatch
                    ? "Read,Grep,Glob,LS,WebFetch,WebSearch,Bash(agentteam:*),Bash(agentteam *)"
                    : "Read,Grep,Glob,LS,WebFetch,WebSearch"
                a += ["--allowedTools", tools]
            }
            return a
        case .codex:
            let sandbox = (r.access == .readOnly && !r.canDispatch) ? "read-only" : "workspace-write"
            var a = ["exec", "--json", "--skip-git-repo-check", "--sandbox", sandbox]
            if !p.model.isEmpty { a += ["-m", p.model] }
            if !p.effort.isEmpty { a += ["-c", "model_reasoning_effort=\(p.effort)"] }
            if let s = r.sessionId { a += ["resume", s] }
            return a + ["-"]
        case .antigravity:
            var a = ["-p", r.prompt, "--output-format", "stream-json", "--dangerously-skip-permissions", "--print-timeout", "60m"]
            if !p.model.isEmpty { a += ["--model", p.model] }
            if !p.effort.isEmpty { a += ["--effort", p.effort] }
            if let s = r.sessionId { a += ["--conversation", s] }
            return a
        }
    }
}

/// Turns one stdout line of a provider's streaming JSON into events.
public struct OutputParser {
    public let provider: Provider
    var lastText = ""

    public init(_ provider: Provider) { self.provider = provider }

    public mutating func feed(_ line: String) -> [RunEvent] {
        guard let data = line.data(using: .utf8),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        switch provider {
        case .claude: return claude(o)
        case .codex: return codex(o)
        case .antigravity: return antigravity(o)
        }
    }

    mutating func claude(_ o: [String: Any]) -> [RunEvent] {
        switch o["type"] as? String {
        case "system":
            var ev: [RunEvent] = []
            if let s = o["session_id"] as? String { ev.append(.session(s)) }
            if let m = o["model"] as? String, !m.isEmpty { ev.append(.modelMetadata(m)) }
            return ev
        case "rate_limit_event":
            let w = Quota.claude(o["rate_limit_info"] as? [String: Any] ?? [:])
            return w.isEmpty ? [] : [.quota(w)]
        case "assistant":
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { c in
                switch c["type"] as? String {
                case "text":
                    guard let t = c["text"] as? String, !t.isEmpty else { return nil }
                    lastText = t
                    return .progress(t)
                case "tool_use":
                    let input = c["input"] as? [String: Any] ?? [:]
                    let detail = (input["command"] ?? input["file_path"] ?? input["pattern"]) as? String ?? ""
                    return .progress("🔧 \(c["name"] as? String ?? "tool") \(String(detail.prefix(160)))")
                default: return nil
                }
            }
        case "result":
            var ev: [RunEvent] = []
            if let s = o["session_id"] as? String { ev.append(.session(s)) }
            if let u = o["usage"] as? [String: Any] {
                ev.append(.usage(int(u, "input_tokens") + int(u, "cache_creation_input_tokens") + int(u, "output_tokens")))
            }
            let text = (o["result"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? lastText
            let failed = (o["is_error"] as? Bool) == true || (o["subtype"] as? String).map { $0 != "success" } == true
            ev.append(failed ? .failure(text.isEmpty ? (o["subtype"] as? String ?? "error") : text) : .final(text))
            return ev
        default:
            return []
        }
    }

    mutating func codex(_ o: [String: Any]) -> [RunEvent] {
        switch o["type"] as? String {
        case "thread.started":
            return (o["thread_id"] as? String).map { [.session($0)] } ?? []
        case "item.started", "item.completed":
            let item = o["item"] as? [String: Any] ?? [:]
            let completed = o["type"] as? String == "item.completed"
            switch item["type"] as? String {
            case "agent_message" where completed:
                guard let t = item["text"] as? String else { return [] }
                lastText = t
                return [.progress(t)]
            case "command_execution" where !completed:
                return [.progress("$ \(String((item["command"] as? String ?? "").prefix(160)))")]
            case "file_change" where completed:
                let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
                return [.progress("✎ \(paths.joined(separator: ", "))")]
            default:
                return []
            }
        case "turn.completed":
            let u = o["usage"] as? [String: Any]
            return [.usage(int(u, "input_tokens") - int(u, "cached_input_tokens") + int(u, "output_tokens")), .final(lastText)]
        case "turn.failed":
            return [.failure((o["error"] as? [String: Any])?["message"] as? String ?? "turn.failed")]
        case "error":
            return [.failure(o["message"] as? String ?? "error")]
        default:
            return []
        }
    }

    mutating func antigravity(_ o: [String: Any]) -> [RunEvent] {
        switch o["event"] as? String {
        case "step_update":
            let s = o["step_update"] as? [String: Any] ?? [:]
            var ev: [RunEvent] = []
            if let id = s["conversation_id"] as? String { ev.append(.session(id)) }
            switch s["step_type"] as? String {
            case "agent_response":
                lastText += s["text_delta"] as? String ?? ""
            case "tool" where s["state"] as? String == "ACTIVE":
                ev.append(.progress("🔧 \(s["tool_name"] as? String ?? "tool")"))
            default:
                break
            }
            return ev
        case "result":
            let r = o["result"] as? [String: Any] ?? [:]
            var ev: [RunEvent] = []
            if let id = r["conversation_id"] as? String { ev.append(.session(id)) }
            if let u = r["usage"] as? [String: Any] {
                ev.append(.usage(int(u, "input_tokens") - int(u, "cache_read_tokens") + int(u, "output_tokens") + int(u, "thinking_tokens")))
            }
            if r["status"] as? String == "SUCCESS" {
                ev.append(.final(r["response"] as? String ?? lastText))
            } else {
                ev.append(.failure(r["error"] as? String ?? (r["status"] as? String ?? "ERROR")))
            }
            return ev
        default:
            return []
        }
    }
}

/// Contextual match on the error text; avoids false positives from bare keywords or line numbers.
public func isLimitError(_ text: String) -> Bool {
    let t = text.lowercased()
    let phrases = [
        "usage limit", "rate limit", "rate_limit", "resource_exhausted",
        "limit reached", "hit your limit", "too many requests", "credit balance",
        "out of credits", "quota exceeded", "exceeded your quota",
        "exceeded your current quota", "over quota", "quota limit", "insufficient_quota",
        "rate_limit_error"
    ]
    if phrases.contains(where: { t.contains($0) }) { return true }
    // Claude: "You've hit your 5-hour limit · resets 12:50am", "hit your weekly limit".
    if t.range(of: #"hit your [a-z0-9 \-]{0,24}limit"#, options: .regularExpression) != nil { return true }

    let patterns429 = [
        "http 429", "http status 429", "error 429", "error: 429", "status: 429", "status 429",
        "code: 429", "code 429", "429 too many", "429 rate limit", "429 quota", "api error: 429"
    ]
    if patterns429.contains(where: { t.contains($0) }) { return true }
    if t.hasPrefix("429 too many") || t.hasPrefix("429 rate limit") || t.hasPrefix("429:") || t.hasPrefix("429 -") { return true }

    return false
}

/// Connection failures: the turn is retried once the network is back instead of failing the work.
public func isNetworkError(_ text: String) -> Bool {
    let t = text.lowercased()
    return ["enotfound", "econnreset", "econnrefused", "etimedout", "eai_again", "enetunreach", "network error",
            "network is unreachable", "could not resolve host", "getaddrinfo", "connection reset", "connection refused",
            "stream disconnected", "socket hang up", "fetch failed", "error sending request", "internet connection appears to be offline",
            "unable to connect", "dns error", "tls handshake"].contains { t.contains($0) }
}

/// When a limit message says the limit resets, e.g. Claude's "resets 12:50am (Asia/Saigon)" or "resets Nov 2, 9am".
/// nil when the text names no time.
public func limitResetDate(_ text: String, now: Date = Date()) -> Date? {
    let pattern = #"resets\s+(?:([A-Za-z]{3})[a-z]*\.? (\d{1,2}),?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)(?:\s*\(([^)]+)\))?"#
    guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
    func g(_ i: Int) -> String? { Range(m.range(at: i), in: text).map { String(text[$0]) } }
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = g(6).flatMap(TimeZone.init(identifier:)) ?? .current
    var hour = Int(g(3)!)! % 12
    if g(5)!.lowercased() == "pm" { hour += 12 }
    var want = DateComponents(hour: hour, minute: Int(g(4) ?? "0") ?? 0)
    if let mon = g(1), let day = g(2).flatMap(Int.init) {
        let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let i = months.firstIndex(of: mon.lowercased()) else { return nil }
        want.month = i + 1
        want.day = day
    }
    return cal.nextDate(after: now, matching: want, matchingPolicy: .nextTime)
}
