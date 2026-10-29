import Foundation

/// One rate-limit window of a subscription, e.g. Claude's 5-hour window or Codex's weekly window.
public struct QuotaWindow: Codable, Hashable, Sendable {
    public var name: String
    public var usedPercent: Double
    public var resetsAt: Date?

    public init(name: String, usedPercent: Double, resetsAt: Date?) {
        self.name = name
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct ProviderQuota: Codable, Hashable, Sendable {
    public var windows: [QuotaWindow]
    public var updated: Date

    public init(windows: [QuotaWindow], updated: Date) {
        self.windows = windows
        self.updated = updated
    }

    /// A window whose reset time has passed is empty again, even before the provider reports new usage
    /// (Claude only reports during a turn).
    public func resettingExpired(now: Date = Date()) -> ProviderQuota {
        var q = self
        for i in q.windows.indices where q.windows[i].resetsAt.map({ $0 <= now }) == true {
            q.windows[i].usedPercent = 0
            q.windows[i].resetsAt = nil
        }
        return q
    }
}

public enum QuotaStatus: Equatable, Sendable {
    case reading
    case noBinary
    case disabled
    case error(message: String, at: Date)
    case available(ProviderQuota)
}

public enum Quota {
    public static var fileOverride: URL?
    public static var workDirOverride: URL?
    public static var codexSessionsOverride: URL?
    public static var codexHomeOverride: URL?

    /// Account-wide, so shared by all projects and kept across restarts.
    public static var file: URL {
        if let override = fileOverride { return override }
        if let env = ProcessInfo.processInfo.environment["AGENTTEAM_QUOTA_FILE"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentTeam/quota.json")
    }

    public static var workDir: URL {
        if let override = workDirOverride { return override }
        if let env = ProcessInfo.processInfo.environment["AGENTTEAM_AGY_USAGE_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        return file.deletingLastPathComponent().appendingPathComponent("agy-usage")
    }

    public static func load() -> [String: ProviderQuota] {
        (try? Data(contentsOf: file)).flatMap { try? jsonDecoder.decode([String: ProviderQuota].self, from: $0) } ?? [:]
    }

    public static func save(_ q: [String: ProviderQuota]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? jsonEncoder.encode(q).write(to: file, options: .atomic)
    }

    static func windowName(minutes: Int) -> String {
        switch minutes {
        case 10080: "7 ngày"
        case let m where m % 1440 == 0: "\(m / 1440) ngày"
        case let m where m % 60 == 0: "\(m / 60) giờ"
        default: "\(minutes) phút"
        }
    }

    /// Claude Code's `rate_limit_event` (stream-json): utilization 0…1 per unified window.
    static func claude(_ info: [String: Any]) -> [QuotaWindow] {
        let names = ["five_hour": "5 giờ", "seven_day": "7 ngày", "seven_day_opus": "7 ngày (Opus)"]
        func date(_ v: Any?) -> Date? { (v as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        if let windows = info["unifiedWindows"] as? [String: [String: Any]] {
            return windows.compactMap { key, w in
                guard let u = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
                return QuotaWindow(name: names[key] ?? key, usedPercent: u * 100, resetsAt: date(w["resetsAt"]))
            }.sorted { $0.name < $1.name }
        }
        guard let u = (info["utilization"] as? NSNumber)?.doubleValue else { return [] }
        let type = info["rateLimitType"] as? String ?? ""
        return [QuotaWindow(name: names[type] ?? type, usedPercent: u * 100, resetsAt: date(info["resetsAt"]))]
    }

    /// Codex `rate_limits` object (session rollout files under ~/.codex/sessions).
    static func codex(_ r: [String: Any]) -> [QuotaWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let w = r[key] as? [String: Any], let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (w["window_minutes"] as? NSNumber)?.intValue ?? 0
            let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return QuotaWindow(name: windowName(minutes: minutes), usedPercent: used, resetsAt: reset)
        }
    }

    /// Latest Codex limits from its newest session file; costs no tokens.
    public static func readCodex(home: URL? = nil) -> ProviderQuota? {
        let root: URL
        if let home {
            root = home.appendingPathComponent(".codex/sessions")
        } else if let sessionsOverride = codexSessionsOverride {
            root = sessionsOverride
        } else if let envSessions = ProcessInfo.processInfo.environment["AGENTTEAM_CODEX_SESSIONS_DIR"], !envSessions.isEmpty {
            root = URL(fileURLWithPath: envSessions)
        } else {
            let h = codexHomeOverride ?? ProcessInfo.processInfo.environment["AGENTTEAM_CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
            root = h.appendingPathComponent(".codex/sessions")
        }
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: (URL, Date)?
        for case let url as URL in e where url.pathExtension == "jsonl" {
            let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if newest == nil || d > newest!.1 { newest = (url, d) }
        }
        guard let (file, modified) = newest, let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let r = (o["payload"] as? [String: Any])?["rate_limits"] as? [String: Any] else { continue }
            let w = codex(r)
            return w.isEmpty ? nil : ProviderQuota(windows: w, updated: modified)
        }
        return nil
    }
}

// MARK: - Antigravity

extension Quota {
    /// Cleans up direct children spawned by the probe wrapper process.
    nonisolated static func cleanProbeChildren(parentPid: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(parentPid)]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        for line in out.split(separator: "\n") {
            if let childPid = Int32(line.trimmingCharacters(in: .whitespaces)), childPid > 1 {
                kill(childPid, SIGTERM)
                usleep(100_000)
                if kill(childPid, 0) == 0 {
                    kill(childPid, SIGKILL)
                }
            }
        }
    }

    /// Drives the Antigravity interactive TUI with a finite deadline, reader timeout,
    /// no blind Enter keystrokes, and robust child cleanup.
    public static func probeAntigravity(binary: String, workDir: URL, timeoutSeconds: Double = 25) -> String? {
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", binary]
        p.currentDirectoryURL = workDir
        let inp = Pipe(), out = Pipe()
        p.standardInput = inp
        p.standardOutput = out
        p.standardError = out
        guard (try? p.run()) != nil else { return nil }
        let pid = p.processIdentifier

        // Removed blind Enter; start straight into /usage
        let keys: [(Double, String)] = [
            (2, "/usage"), (1.5, "\r"),
            (7, "\u{1b}[6~"), (1, "\u{1b}[6~"), (1, "\u{1b}[6~"), (1, "\u{1b}[6~"),   // page through all groups
            (1, "\u{1b}"), (1, "/exit"), (1, "\r"),
        ]
        let w = inp.fileHandleForWriting
        DispatchQueue.global().async {
            for (delay, k) in keys {
                Thread.sleep(forTimeInterval: delay)
                guard p.isRunning else { return }
                try? w.write(contentsOf: Data(k.utf8))
            }
        }

        var data = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        // Wait with finite deadline
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while p.isRunning && Date() < deadline {
            usleep(100_000)
        }

        if p.isRunning {
            p.terminate()
            var exited = false
            for _ in 0..<20 {
                usleep(100_000)
                if !p.isRunning { exited = true; break }
            }
            if !exited {
                kill(pid, SIGKILL)
            }
        }

        cleanProbeChildren(parentPid: pid)
        try? inp.fileHandleForWriting.close()

        _ = group.wait(timeout: .now() + 2)
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Parses the `/usage` panel: per model group, "… Limit Remaining" + "[███░░] 67.74%" + "Refreshes in 116h 24m".
    public static func parseAntigravity(_ raw: String, now: Date = Date()) -> [QuotaWindow] {
        var text = raw
        for pattern in ["\u{1b}\\[[0-9;?<>]*[ -/]*[@-~]", "\u{1b}\\][^\u{07}]*\u{07}", "\u{1b}[()][A-Z0-9]"] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "\r", with: "\n")

        func groupName(_ line: String) -> String {
            line.hasPrefix("GEMINI") ? "Gemini" : line.hasPrefix("CLAUDE") ? "Claude/GPT" : line.capitalized
        }
        func windowName(_ label: String) -> String {
            let span = label.contains("Five Hour") ? "5 giờ" : label.contains("Weekly") ? "tuần" : label
            let model = label.components(separatedBy: " Weekly").first.flatMap { $0.hasPrefix("Weekly") || $0 == label ? nil : $0 }
            return model.map { "\($0) · \(span)" } ?? span
        }

        var group = "", label = ""
        var result: [String: QuotaWindow] = [:]
        var order: [String] = []
        var lastKey: String?
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(" MODELS") { group = groupName(line); continue }
            if line.contains("Limit"), !line.contains("%") { label = line; lastKey = nil; continue }
            if line.hasPrefix("["), let r = line.range(of: #"([0-9]+(\.[0-9]+)?)%$"#, options: .regularExpression),
               let remaining = Double(line[r].dropLast()), !label.isEmpty {
                let isModelSpecific = !label.hasPrefix("Weekly") && !label.hasPrefix("Five")
                let name = isModelSpecific ? windowName(label) : "\(group) · \(windowName(label))"
                if result[name] == nil { order.append(name) }
                result[name] = QuotaWindow(name: name, usedPercent: max(0, 100 - remaining), resetsAt: result[name]?.resetsAt)
                lastKey = name
                continue
            }
            if line.hasPrefix("Refreshes in"), let key = lastKey {
                let h = line.range(of: #"([0-9]+)h"#, options: .regularExpression).flatMap { Double(line[$0].dropLast()) } ?? 0
                let m = line.range(of: #"([0-9]+)m"#, options: .regularExpression).flatMap { Double(line[$0].dropLast()) } ?? 0
                result[key]?.resetsAt = now.addingTimeInterval(h * 3600 + m * 60)
            }
        }
        return order.compactMap { result[$0] }
    }
}
