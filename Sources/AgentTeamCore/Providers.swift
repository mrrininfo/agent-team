import Foundation

public struct TurnRequest: Sendable {
    public var prompt: String
    public var profile: Profile
    public var sessionId: String?
    public var access: Access

    public init(prompt: String, profile: Profile, sessionId: String?, access: Access) {
        self.prompt = prompt
        self.profile = profile
        self.sessionId = sessionId
        self.access = access
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
}

private func int(_ d: [String: Any]?, _ k: String) -> Int { (d?[k] as? NSNumber)?.intValue ?? 0 }

extension Provider {
    /// claude and codex read the prompt from stdin (no argv size limit); agy takes it as the -p value.
    public var promptViaStdin: Bool { self != .antigravity }

    public func arguments(_ r: TurnRequest) -> [String] {
        let p = r.profile
        switch self {
        case .claude:
            var a = ["-p", "--output-format", "stream-json", "--verbose"]
            if !p.model.isEmpty { a += ["--model", p.model] }
            if let s = r.sessionId { a += ["--resume", s] }
            a += r.access == .write
                ? ["--dangerously-skip-permissions"]
                : ["--allowedTools", "Read,Grep,Glob,LS,WebFetch,WebSearch,Bash(agentteam:*),Bash(agentteam *)"]
            return a
        case .codex:
            // workspace-write even for read-only roles: `agentteam` must write the inbox inside the workspace.
            var a = ["exec", "--json", "--skip-git-repo-check", "--sandbox", "workspace-write"]
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
            return (o["session_id"] as? String).map { [.session($0)] } ?? []
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

/// shortcut: keyword match on the error text; providers do not document a stable limit error code yet.
public func isLimitError(_ text: String) -> Bool {
    let t = text.lowercased()
    return ["usage limit", "rate limit", "rate_limit", "quota", "resource_exhausted", "limit reached",
            "hit your limit", "too many requests", "429", "credit balance", "out of credits"].contains { t.contains($0) }
}
