import Foundation

/// Runs provider CLIs as child processes, one per turn.
@MainActor
public final class ProcessRunner {
    var processes: [String: Process] = [:]
    /// Folder holding the `agentteam` helper; prepended to PATH so agents can call it by name.
    public var helperDir: URL?
    public let searchPath: String

    public init(helperDir: URL?) {
        self.helperDir = helperDir
        searchPath = ProcessRunner.loginPath()
    }

    /// GUI apps get a minimal PATH; ask the login shell for the user's real one (nvm, homebrew, ~/.local/bin…).
    nonisolated public static func loginPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extras = ["\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-ilc", "printf '\\n__PATH__%s' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var shellPath = ""
        if (try? p.run()) != nil {
            let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            shellPath = s.components(separatedBy: "__PATH__").last ?? ""
        }
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return ([shellPath] + extras + [base]).filter { !$0.isEmpty }.joined(separator: ":")
    }

    public func binary(for provider: Provider, override: String? = nil) -> String? {
        if let o = override, !o.isEmpty {
            let path = (o as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        return searchPath.split(separator: ":").map { "\($0)/\(provider.binaryName)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func cancel(_ chatId: String) { processes[chatId]?.terminate() }

    /// `binaryPath` is the workspace's custom path for this provider, if any (several workspaces share one runner).
    public func run(chatId: String, request: TurnRequest, cwd: URL, binaryPath: String? = nil,
                    onEvent: @escaping @MainActor (RunEvent) -> Void) async -> String? {
        let provider = request.profile.provider
        guard let bin = binary(for: provider, override: binaryPath) else {
            return "Không tìm thấy lệnh `\(provider.binaryName)`. Cài \(provider.title) CLI hoặc nhập đường dẫn trong tab Team."
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = provider.arguments(request)
        proc.currentDirectoryURL = cwd
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ([helperDir?.path].compactMap { $0 } + [searchPath]).joined(separator: ":")
        env["AGENTTEAM_CHAT"] = chatId
        env["AGENTTEAM_DIR"] = TeamPaths(workspace: cwd).root.path
        proc.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = provider.promptViaStdin ? inp : FileHandle.nullDevice
        let exited = AsyncStream<Int32> { c in
            proc.terminationHandler = { c.yield($0.terminationStatus); c.finish() }
        }
        do { try proc.run() } catch { return "Không chạy được \(bin): \(error.localizedDescription)" }
        processes[chatId] = proc
        defer { processes[chatId] = nil }

        if provider.promptViaStdin {
            let data = Data(request.prompt.utf8), h = inp.fileHandleForWriting
            Task.detached { h.write(data); try? h.close() }
        }
        let errHandle = err.fileHandleForReading
        let stderrTask = Task.detached { String(decoding: errHandle.readDataToEndOfFile(), as: UTF8.self) }

        var parser = OutputParser(provider)
        do {
            for try await line in out.fileHandleForReading.bytes.lines {
                for e in parser.feed(line) { onEvent(e) }
            }
        } catch {}
        var status: Int32 = 0
        for await s in exited { status = s }
        let stderr = await stderrTask.value
        return status == 0 ? nil : "exit \(status): " + tail(stderr.trimmingCharacters(in: .whitespacesAndNewlines), 1500)
    }
}
