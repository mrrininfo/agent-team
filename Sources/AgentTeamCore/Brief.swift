import Foundation

/// The request a dispatching chat (the Lead) is working on, pinned in a file so it survives compaction and hand-offs.
/// The app appends the user's messages verbatim; the Lead fills in the criteria and the out-of-scope list.
public enum Brief {
    static let requests = "## Yêu cầu của người dùng (nguyên văn)"
    static let criteria = "## Tiêu chí xong"
    static let outOfScope = "## Ngoài phạm vi"

    public static func record(_ text: String, at date: Date, file: URL) {
        var s = (try? String(contentsOf: file, encoding: .utf8))
            ?? "\(requests)\n\n\(criteria)\n(Lead viết: mỗi tiêu chí một dòng, kiểm chứng được)\n\n\(outOfScope)\n(Lead viết)\n"
        let entry = "### \(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)))\n\(text)\n\n"
        if let r = s.range(of: criteria) { s.insert(contentsOf: entry, at: r.lowerBound) } else { s += entry }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? s.write(to: file, atomically: true, encoding: .utf8)
    }

    /// What goes on top of every Lead turn: the first request, the latest three, and the Lead's criteria, within `limit`.
    public static func block(_ file: URL, limit: Int = 3000) -> String? {
        guard let s = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let split = s.range(of: criteria).map { (String(s[..<$0.lowerBound]), String(s[$0.lowerBound...])) } ?? (s, "")
        let entries = split.0.components(separatedBy: "\n### ").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = entries.first else { return nil }
        let latest = Array(entries.dropFirst().suffix(3))
        let head = "# ĐỀ BÀI ĐANG LÀM (file \(file.lastPathComponent); đáp án cuối phải trả lời đúng đề bài này)\n"
        let rest = clip(split.1.trimmingCharacters(in: .whitespacesAndNewlines), 700)
        // The middle requests are clipped first: the first one says what was asked, the latest ones what changed since.
        let budget = max(200, limit - head.count - rest.count - 120)
        let firstPart = clip(first, latest.isEmpty ? budget : budget / 3)
        let each = latest.isEmpty ? 0 : (budget - firstPart.count) / latest.count
        var out = head + "## Yêu cầu đầu tiên\n" + firstPart + "\n"
        if !latest.isEmpty { out += "## Yêu cầu gần nhất\n" + latest.map { clip($0, max(80, each)) }.joined(separator: "\n") + "\n" }
        out += rest + "\n\n"
        return out.count <= limit ? out : String(out.prefix(limit))
    }

    /// Ends the current request: the file moves to `done/` and the next message starts a fresh brief.
    public static func close(_ file: URL, doneDir: URL, now: Date = Date()) {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try? FileManager.default.createDirectory(at: doneDir, withIntermediateDirectories: true)
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        try? FileManager.default.moveItem(at: file, to: doneDir.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent)-\(stamp).md"))
    }
}
