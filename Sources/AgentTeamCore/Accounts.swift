import Foundation
import Security

/// A further sign-in or API key for a provider. The CLI's own login is the implicit default account and is not listed.
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case login, apiKey }

    public var id: String
    public var provider: Provider
    public var label: String
    public var kind: Kind
    /// API accounts only: another service speaking this provider's API (e.g. Meta's Model API for Muse through Claude Code).
    /// Its models differ from the provider's own, so it serves only profiles that name it and never joins the rotation.
    public var baseURL: String?
    /// API accounts only: tokens per day before the account is parked until midnight, so an unattended night cannot run up a bill.
    public var dailyTokenCap: Int?
    public var enabled = true

    public init(id: String = shortId(), provider: Provider, label: String, kind: Kind, baseURL: String? = nil, dailyTokenCap: Int? = nil) {
        self.id = id
        self.provider = provider
        self.label = label
        self.kind = kind
        self.baseURL = baseURL
        self.dailyTokenCap = dailyTokenCap
    }

    /// Takes over automatically when the default account (and the ones before it) hit their limit.
    public var rotates: Bool { enabled && (baseURL ?? "").isEmpty }
}

/// Machine-wide accounts (shared by every project), their per-day token use, and their API keys in the Keychain.
public enum AccountStore {
    // shortcut: unsynchronised global, written on the main thread only; move into an actor if accounts change off-main.
    nonisolated(unsafe) public static var accounts: [Account] = []
    nonisolated(unsafe) public static var root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentTeam")
    /// Replaced by the checks so they never touch the real Keychain.
    nonisolated(unsafe) public static var keyLookup: (String) -> String? = { Keychain.read($0) }

    static var file: URL { root.appendingPathComponent("accounts.json") }
    static var usageFile: URL { root.appendingPathComponent("account-usage.json") }

    public static func find(_ id: String) -> Account? { accounts.first { $0.id == id } }
    public static func rotation(_ p: Provider) -> [Account] { accounts.filter { $0.provider == p && $0.rotates } }

    public static func load() {
        accounts = (try? Data(contentsOf: file)).flatMap { try? jsonDecoder.decode([Account].self, from: $0) } ?? []
    }

    public static func save() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? jsonEncoder.encode(accounts).write(to: file, options: .atomic)
    }

    /// Removes the account, its sign-in folder and its key.
    public static func remove(_ id: String) {
        accounts.removeAll { $0.id == id }
        save()
        try? FileManager.default.removeItem(at: dir(id))
        Keychain.delete(id)
    }

    /// The account's own config folder: CLAUDE_CONFIG_DIR, CODEX_HOME, or the HOME agy runs with.
    public static func dir(_ id: String) -> URL { root.appendingPathComponent("accounts/\(id)") }

    /// Environment that points the CLI at this account; empty for the default account.
    public static func environment(_ id: String?) -> [String: String] {
        guard let id, let a = find(id) else { return [:] }
        let d = dir(id)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let key = a.kind == .apiKey ? keyLookup(id) : nil
        switch a.provider {
        case .claude:
            var env = ["CLAUDE_CONFIG_DIR": d.path]
            if let key { env["ANTHROPIC_API_KEY"] = key }
            if let u = a.baseURL, !u.isEmpty { env["ANTHROPIC_BASE_URL"] = u }
            return env
        case .codex:
            var env = ["CODEX_HOME": d.path]
            if let key { env["OPENAI_API_KEY"] = key }
            return env
        case .antigravity:
            return ["HOME": agyHome(d).path]
        }
    }

    /// agy has no config-dir option and keeps its sign-in in ~/.gemini/antigravity-cli, so each account runs with its own
    /// HOME. Everything else in the real home is linked in, so tools, git config and project paths behave as usual;
    /// agy's settings and MCP config are linked too, while its sign-in and conversations stay per account.
    public static func agyHome(_ d: URL, realHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let fm = FileManager.default
        func link(_ name: String, from src: URL, into dst: URL) {
            let target = dst.appendingPathComponent(name)
            guard (try? fm.destinationOfSymbolicLink(atPath: target.path)) == nil, !fm.fileExists(atPath: target.path) else { return }
            try? fm.createSymbolicLink(at: target, withDestinationURL: src.appendingPathComponent(name))
        }
        let cli = d.appendingPathComponent(".gemini/antigravity-cli")
        try? fm.createDirectory(at: cli, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: realHome.path)) ?? [] where name != ".gemini" { link(name, from: realHome, into: d) }
        link("config", from: realHome.appendingPathComponent(".gemini"), into: d.appendingPathComponent(".gemini"))
        let realCli = realHome.appendingPathComponent(".gemini/antigravity-cli")
        for name in ["bin", "builtin", "mcp", "settings.json", "updater"] where fm.fileExists(atPath: realCli.appendingPathComponent(name).path) {
            link(name, from: realCli, into: cli)
        }
        return d
    }

    /// Adds today's tokens for the account; true once its daily cap is reached.
    public static func addUsage(_ id: String, tokens: Int, now: Date = Date()) -> Bool {
        guard let a = find(id) else { return false }
        let day = ISO8601DateFormatter.string(from: now, timeZone: .current, formatOptions: [.withFullDate])
        var usage = (try? Data(contentsOf: usageFile)).flatMap { try? jsonDecoder.decode([String: [String: Int]].self, from: $0) } ?? [:]
        let total = (usage[id]?[day] ?? 0) + max(0, tokens)
        usage[id] = [day: total]
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? jsonEncoder.encode(usage).write(to: usageFile, options: .atomic)
        return a.dailyTokenCap.map { total >= $0 } ?? false
    }
}

/// API keys live in the login Keychain, never in a file.
public enum Keychain {
    static let service = "AgentTeam API key"

    public static func save(_ key: String, for id: String) {
        delete(id)
        SecItemAdd([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id,
                    kSecValueData: Data(key.utf8)] as CFDictionary, nil)
    }

    public static func read(_ id: String) -> String? {
        var out: CFTypeRef?
        let q = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id,
                 kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary
        guard SecItemCopyMatching(q, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    public static func delete(_ id: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: id] as CFDictionary)
    }
}
