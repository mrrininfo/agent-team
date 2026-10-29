import Foundation

/// Files attached to a user message are copied into the project and listed under this marker, one "- path" per line,
/// so every provider can open them by path.
public enum Attachments {
    public static let marker = "📎 Đính kèm:"

    public static func paths(in text: String) -> [String] {
        guard let r = text.range(of: marker) else { return [] }
        var out: [String] = []
        for line in text[r.upperBound...].split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") else { break }
            out.append(String(t.dropFirst(2)))
        }
        return out
    }
}

/// A link or path from a message as an existing local file: absolute, `~/…`, or relative to the workspace;
/// a trailing `:line` is ignored. nil for web links and missing files.
public func resolveLocal(_ url: URL, root: URL) -> URL? {
    var path: String
    if url.isFileURL || url.scheme == nil {
        path = url.path
    } else if !url.absoluteString.contains("://") {
        // "README.md:12" parses as scheme "README.md"; it is still a path.
        path = url.absoluteString.removingPercentEncoding ?? url.absoluteString
    } else {
        return nil
    }
    if path.isEmpty { return nil }
    if path.hasPrefix("~") { path = NSString(string: path).expandingTildeInPath }
    let noLine = path.replacingOccurrences(of: #":\d+(:\d+)?$"#, with: "", options: .regularExpression)
    for p in [path, noLine] {
        let u = p.hasPrefix("/") ? URL(fileURLWithPath: p) : root.appendingPathComponent(p)
        if FileManager.default.fileExists(atPath: u.path) { return u.standardizedFileURL }
    }
    return nil
}

/// Turns file paths that exist (bare or in `code`) into markdown links, so agents' "see report X" is clickable.
public func linkifyPaths(_ text: String, root: URL) -> String {
    let pattern = #"`([^`\n]+)`|(?<![\[(\w/.\-])((?:~/|\.{1,2}/|/)?[\w@+\-]+(?:[./][\w@+\-]+)*\.[A-Za-z0-9]{1,8}(?::\d+)?)"#
    guard let re = try? NSRegularExpression(pattern: pattern) else { return text }
    let ns = text as NSString
    var out = "", last = 0
    for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let r = m.range(at: 1).location != NSNotFound ? m.range(at: 1) : m.range(at: 2)
        let token = ns.substring(with: r)
        guard !token.contains(where: { "[]()<>".contains($0) }),
              let enc = token.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let u = URL(string: enc), resolveLocal(u, root: root) != nil else { continue }
        out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
        out += "[\(token)](\(enc))"
        last = m.range.location + m.range.length
    }
    return out + ns.substring(from: last)
}
