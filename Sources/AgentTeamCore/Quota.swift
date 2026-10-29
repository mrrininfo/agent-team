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
}

public enum Quota {
    /// Account-wide, so shared by all projects and kept across restarts.
    public static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentTeam/quota.json")
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
    public static func readCodex(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ProviderQuota? {
        let root = home.appendingPathComponent(".codex/sessions")
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
