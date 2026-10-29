import Foundation

/// Written by `agentteam dispatch` into `.agentteam/inbox/`, consumed by the app.
public struct DispatchRequest: Codable, Sendable {
    public var id: String
    public var from: String
    public var to: String
    public var title: String?
    public var tab: String?
    public var body: String

    public init(id: String = shortId(), from: String, to: String, title: String?, tab: String?, body: String) {
        self.id = id
        self.from = from
        self.to = to
        self.title = title
        self.tab = tab
        self.body = body
    }
}

public struct DispatchAck: Codable, Sendable {
    public var id: String
    public var disposition: String  // queued | started | rejected
    public var chatId: String?
    public var reason: String?

    public init(id: String, disposition: String, chatId: String? = nil, reason: String? = nil) {
        self.id = id
        self.disposition = disposition
        self.chatId = chatId
        self.reason = reason
    }
}

public struct TeamPaths: Sendable {
    public let root: URL

    public init(workspace: URL) { root = workspace.appendingPathComponent(".agentteam", isDirectory: true) }

    public var workspace: URL { root.deletingLastPathComponent() }
    public var teamFile: URL { root.appendingPathComponent("team.json") }
    public var rosterFile: URL { root.appendingPathComponent("roster.txt") }
    public var inbox: URL { root.appendingPathComponent("inbox", isDirectory: true) }
    public var acks: URL { inbox.appendingPathComponent("acks", isDirectory: true) }
    public var chats: URL { root.appendingPathComponent("chats", isDirectory: true) }
    public var notes: URL { root.appendingPathComponent("notes", isDirectory: true) }
    /// chatId → pid of the provider process running that chat's turn; lets a relaunch stop orphans.
    public var runningFile: URL { root.appendingPathComponent("running.json") }

    public func chatFile(_ id: String) -> URL { chats.appendingPathComponent("\(id).json") }
    public func noteFile(_ id: String) -> URL { notes.appendingPathComponent("\(id).md") }
    public func ackFile(_ id: String) -> URL { acks.appendingPathComponent("\(id).json") }

    public func ensure() throws {
        for d in [inbox, acks, chats, notes] {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let ignore = root.appendingPathComponent(".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path) { try "*\n".write(to: ignore, atomically: true, encoding: .utf8) }
    }

    /// Walks up from `dir` to the nearest folder containing `.agentteam`.
    public static func find(from dir: URL) -> TeamPaths? {
        var d = dir.standardizedFileURL
        while true {
            let p = TeamPaths(workspace: d)
            if FileManager.default.fileExists(atPath: p.teamFile.path) { return p }
            let up = d.deletingLastPathComponent()
            if up.path == d.path { return nil }
            d = up
        }
    }
}

public let jsonEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    return e
}()

public let jsonDecoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()
