import Foundation

/// The request a dispatching chat (the Lead) is working on, pinned so it survives compaction and hand-offs.
/// Two files, so the app and the Lead never overwrite each other: the app appends the user's messages verbatim to
/// `<id>.requests.md`; the Lead keeps the criteria and the out-of-scope list in `<id>.md`.
public enum Brief {
    static let criteria = "## Tiêu chí xong"
    static let outOfScope = "## Ngoài phạm vi"
    /// Requests are fenced by HTML comments, not headings: pasted markdown (### A, ## Tiêu chí xong…) stays inside its request.
    static let entryMark = "<!-- yêu cầu "

    public static func requestsFile(_ file: URL) -> URL {
        file.deletingPathExtension().appendingPathExtension("requests.md")
    }

    public static func record(_ text: String, at date: Date, file: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) {
            let template = "<!-- Yêu cầu nguyên văn của người dùng: \(requestsFile(file).lastPathComponent) (app ghi, đừng sửa) -->\n\n"
                + "\(criteria)\n(Lead viết: mỗi tiêu chí một dòng, kiểm chứng được)\n\n\(outOfScope)\n(Lead viết)\n"
            try? template.write(to: file, atomically: true, encoding: .utf8)
        }
        let safe = text.replacingOccurrences(of: "<!--", with: "< !--")
        let entry = "\(entryMark)\(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))) -->\n\(safe)\n\n"
        let req = requestsFile(file)
        if let h = try? FileHandle(forWritingTo: req) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(entry.utf8))
            try? h.close()
        } else {
            try? entry.write(to: req, atomically: true, encoding: .utf8)
        }
    }

    /// What goes on top of every Lead turn: the first request, the latest three, and the Lead's criteria, within `limit`.
    public static func block(_ file: URL, limit: Int = 3000) -> String? {
        guard let s = try? String(contentsOf: requestsFile(file), encoding: .utf8) else { return nil }
        let entries = s.components(separatedBy: entryMark).dropFirst()
            .map { e in e.range(of: "-->").map { String(e[$0.upperBound...]) } ?? e }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let first = entries.first else { return nil }
        let latest = Array(entries.dropFirst().suffix(3))
        let head = "# ĐỀ BÀI ĐANG LÀM (file \(file.lastPathComponent); đáp án cuối phải trả lời đúng đề bài này)\n"
        let lead = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let rest = clip(lead.components(separatedBy: .newlines).filter { !$0.hasPrefix("<!--") }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines), 700)
        // The middle requests are clipped first: the first one says what was asked, the latest ones what changed since.
        let budget = max(200, limit - head.count - rest.count - 120)
        let firstPart = clip(first, latest.isEmpty ? budget : budget / 3)
        let each = latest.isEmpty ? 0 : (budget - firstPart.count) / latest.count
        var out = head + "## Yêu cầu đầu tiên\n" + firstPart + "\n"
        if !latest.isEmpty { out += "## Yêu cầu gần nhất\n" + latest.map { clip($0, max(80, each)) }.joined(separator: "\n---\n") + "\n" }
        out += rest + "\n\n"
        return out.count <= limit ? out : String(out.prefix(limit))
    }

    /// Ends the current request: both files move to `done/` and the next message starts a fresh brief.
    public static func close(_ file: URL, doneDir: URL, now: Date = Date()) {
        let fm = FileManager.default
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: "")
        let base = file.deletingPathExtension().lastPathComponent
        for (src, suffix) in [(file, ".md"), (requestsFile(file), ".requests.md")] where fm.fileExists(atPath: src.path) {
            try? fm.createDirectory(at: doneDir, withIntermediateDirectories: true)
            try? fm.moveItem(at: src, to: doneDir.appendingPathComponent("\(base)-\(stamp)\(suffix)"))
        }
    }

    /// Moves an open brief to another chat's files (a Lead chat handed over to a fresh one).
    public static func move(_ from: URL, to: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: requestsFile(from).path), !fm.fileExists(atPath: requestsFile(to).path) else { return }
        for (src, dst) in [(from, to), (requestsFile(from), requestsFile(to))] where fm.fileExists(atPath: src.path) {
            try? fm.moveItem(at: src, to: dst)
        }
    }
}
