import Foundation

/// What removing a project takes off the machine besides its folder: the CLI sessions it ran. Matched by the session ids
/// its chats hold, the Claude folder named after its path, the cwd Codex records, and the Agent Team contract that opens
/// every agy conversation ("Workspace: <path>"). A sibling folder whose name merely starts the same is never matched.
public enum ProjectCleanup {
    /// Where the CLIs keep sessions: their own folders and each extra account's.
    public static func cliRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let accounts = (try? FileManager.default.contentsOfDirectory(at: AccountStore.root.appendingPathComponent("accounts"),
                                                                     includingPropertiesForKeys: nil)) ?? []
        return [home.appendingPathComponent(".claude"), home.appendingPathComponent(".codex"),
                home.appendingPathComponent(".gemini/antigravity-cli")]
            + accounts.flatMap { [$0, $0.appendingPathComponent(".gemini/antigravity-cli")] }
    }

    /// Claude Code names a project's session folder after its path, every character other than a-z, A-Z, 0-9 turned into "-".
    public static func claudeFolderName(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    public static func residue(workspace: URL, sessionIds: Set<String>, roots: [URL]) -> [URL] {
        let fm = FileManager.default
        let path = workspace.standardizedFileURL.path
        func inside(_ p: String) -> Bool { p == path || p.hasPrefix(path + "/") }
        // Account folders link the real home's items in; following those links would reach files of other roots.
        func isLink(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true }
        func children(_ d: URL) -> [URL] { isLink(d) ? [] : (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [] }
        func firstJSON(_ f: URL) -> [String: Any]? {
            guard let h = try? FileHandle(forReadingFrom: f) else { return nil }
            defer { try? h.close() }
            let head = (try? h.read(upToCount: 256 * 1024)) ?? Data()
            let line = head.split(separator: UInt8(ascii: "\n"), maxSplits: 1).first.map { Data($0) } ?? head
            return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
        }

        var out: [URL] = []
        for root in roots {
            for p in children(root.appendingPathComponent("projects")) {
                if p.lastPathComponent == claudeFolderName(path) { out.append(p); continue }
                out += children(p).filter { $0.pathExtension == "jsonl" && sessionIds.contains($0.deletingPathExtension().lastPathComponent) }
            }
            let sessions = root.appendingPathComponent("sessions")
            if !isLink(sessions), let e = fm.enumerator(at: sessions, includingPropertiesForKeys: nil) {
                for case let f as URL in e where f.pathExtension == "jsonl" {
                    let name = f.deletingPathExtension().lastPathComponent
                    let cwd = (firstJSON(f)?["payload"] as? [String: Any])?["cwd"] as? String
                    if sessionIds.contains(where: { name.hasSuffix("-" + $0) }) || cwd.map(inside) == true { out.append(f) }
                }
            }
            for b in children(root.appendingPathComponent("brain")) {
                let id = b.lastPathComponent
                let content = firstJSON(b.appendingPathComponent(".system_generated/logs/transcript.jsonl"))?["content"] as? String
                guard sessionIds.contains(id) || content?.contains("Workspace: \(path)\n") == true else { continue }
                out.append(b)
                let db = root.appendingPathComponent("conversations/\(id).db")
                if fm.fileExists(atPath: db.path) { out.append(db) }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    /// Why the folder must not be removed whole, or nil: it holds the home folder, or another project lives inside it.
    public static func refusal(workspace: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = workspace.standardizedFileURL.path, homePath = home.standardizedFileURL.path
        if path == "/" || homePath == path || homePath.hasPrefix(path + "/") {
            return "Không gỡ \(path): thư mục này chứa thư mục người dùng."
        }
        var nested: [String] = []
        let skip: Set = ["node_modules", ".build", "build", "dist", "Pods", "DerivedData", "graphify-out"]
        if let e = FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: [.isDirectoryKey],
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let d as URL in e {
                guard (try? d.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                if skip.contains(d.lastPathComponent) || e.level >= 5 { e.skipDescendants(); continue }
                if FileManager.default.fileExists(atPath: d.appendingPathComponent(".agentteam/team.json").path) {
                    nested.append(String(d.path.dropFirst(path.count + 1)))
                }
            }
        }
        return nested.isEmpty ? nil
            : "Không gỡ: trong thư mục này còn dự án khác (\(nested.prefix(5).joined(separator: ", "))). Chuyển chúng ra ngoài trước."
    }
}
