import Foundation

/// The skeleton a coding role gets with its work: what to build, where, against which tests, and what not to touch.
public enum TaskCard {
    public static let sections = ["Mục tiêu", "File được sửa", "Khung code", "Test nghiệm thu", "Ngoài phạm vi"]

    /// Sections with no `## <name>` heading, or with nothing under it.
    public static func missing(in text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        return sections.filter { name in
            guard let i = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("## \(name)") == .orderedSame })
            else { return true }
            let body = lines[(i + 1)...].prefix { !$0.hasPrefix("## ") }
            return body.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
    }

    /// The card's text if `path` is a readable file inside `workspace`, else why not.
    public static func load(_ path: String, workspace: URL) -> Result<String, CardError> {
        let ws = workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : workspace.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard url.path.hasPrefix(ws + "/") else { return .failure(.outside) }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .failure(.unreadable) }
        return .success(text)
    }

    public enum CardError: Error { case outside, unreadable }
}
