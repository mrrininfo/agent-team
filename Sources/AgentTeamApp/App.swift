import AgentTeamCore
import AppKit
import SwiftUI

@main
struct AgentTeamApp: App {
    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        // `kill`/SIGTERM would otherwise exit without willTerminate, leaving agent processes running unattended.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler { NSApp.terminate(nil) }
        src.resume()
        Self.sigterm = src
    }

    static var sigterm: DispatchSourceSignal?

    var body: some Scene {
        // One window = one project. A window opened for a path (openWindow(value:)) opens that project;
        // ⌘N gives an empty window that reopens the most recent free project.
        WindowGroup("Agent Team", for: String.self) { $path in
            WindowRoot(path: path).frame(minWidth: 980, minHeight: 600)
        }
        .commands { OpenProjectCommands() }
    }
}

struct OpenProjectCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Mở dự án trong cửa sổ mới…") {
                if let url = AppModel.pickFolder() { openWindow(value: url.standardizedFileURL.path) }
            }
            .keyboardShortcut("o")
        }
    }
}

struct WindowRoot: View {
    let path: String?
    @State private var model = AppModel()

    var body: some View {
        RootView()
            .environment(model)
            .background(WindowAccessor(model: model, path: path))
    }
}

/// Hooks the real NSWindow: releases the project when the window closes (✕), and saves/restores its frame.
/// SwiftUI's own frame restoration is unreliable here (its key changes between builds, closed windows keep it).
struct WindowAccessor: NSViewRepresentable {
    let model: AppModel
    let path: String?
    static let frameKey = "windowFrame"

    final class Coordinator {
        var observers: [NSObjectProtocol] = []
        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { [model, path] in
            guard let w = v.window, model.window == nil else { return }
            restoreFrame(w)
            model.attached(to: w, path: path)
            let nc = NotificationCenter.default
            let save = { (_: Notification) in
                MainActor.assumeIsolated { UserDefaults.standard.set(NSStringFromRect(w.frame), forKey: Self.frameKey) }
            }
            context.coordinator.observers = [
                nc.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: w, queue: .main, using: save),
                nc.addObserver(forName: NSWindow.didMoveNotification, object: w, queue: .main, using: save),
                nc.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { n in
                    save(n)
                    MainActor.assumeIsolated { model.windowClosed = true; model.close() }
                },
                nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { n in
                    save(n)
                    MainActor.assumeIsolated { model.close() }
                },
            ]
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor func restoreFrame(_ w: NSWindow) {
        guard let s = UserDefaults.standard.string(forKey: Self.frameKey) else { return }
        var f = NSRectFromString(s)
        guard f.width >= 600, f.height >= 400, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f) }) else { return }
        // Further windows open slightly offset so they do not hide the first one.
        let others = NSApp.windows.filter { $0 !== w && $0.isVisible && $0.frame.width >= 600 }.count
        f = f.offsetBy(dx: CGFloat(others) * 28, dy: CGFloat(others) * -28)
        w.setFrame(f, display: true)
    }
}

@MainActor @Observable
final class AppModel {
    /// Shared by all windows: resolving the login-shell PATH is slow, and processes are keyed by unique chat ids.
    static let runner = ProcessRunner(helperDir: Bundle.main.executableURL?.deletingLastPathComponent())

    final class Owner {
        weak var model: AppModel?
        init(_ m: AppModel) { model = m }
    }
    /// Workspace path → window model that has it open; two orchestrators on one folder would both consume its inbox.
    static var owners: [String: Owner] = [:]

    /// The window currently holding `path`, ignoring windows that were closed or switched projects.
    static func liveOwner(_ path: String) -> AppModel? {
        guard let m = owners[path]?.model, !m.windowClosed, m.window?.isVisible == true,
              m.orchestrator?.paths.workspace.standardizedFileURL.path == path else {
            // Abandoned (window gone/hidden): pause its orchestrator so only one ever drives this folder.
            if let stale = owners[path]?.model, stale.orchestrator?.paths.workspace.standardizedFileURL.path == path { stale.close() }
            owners[path] = nil
            return nil
        }
        return m
    }

    var orchestrator: Orchestrator?
    var error: String?
    /// Bumped when the static recent list changes, so views re-read it.
    var recentVersion = 0
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var windowClosed = false
    var runner: ProcessRunner { Self.runner }

    static var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: "recentWorkspaces") ?? [UserDefaults.standard.string(forKey: "workspace")].compactMap { $0 } }
        set { UserDefaults.standard.set(Array(newValue.prefix(8)), forKey: "recentWorkspaces") }
    }

    /// Called once the model has a real window. Not in init: SwiftUI may build throwaway models for a window,
    /// and those must not claim a project.
    func attached(to w: NSWindow, path: String?) {
        window = w
        if let path {
            // Window opened for a project that is already open elsewhere: show that one, drop this empty window.
            if let other = Self.liveOwner(path), other !== self {
                other.window?.makeKeyAndOrderFront(nil)
                w.close()
                return
            }
            open(URL(fileURLWithPath: path))
        } else if orchestrator == nil, let p = Self.recent.first, FileManager.default.fileExists(atPath: p), Self.liveOwner(p) == nil {
            open(URL(fileURLWithPath: p))
        }
    }

    /// The name the user gave the project (stored in its team.json), else the folder name.
    static func displayName(_ path: String) -> String {
        let file = TeamPaths(workspace: URL(fileURLWithPath: path)).teamFile
        return (try? Data(contentsOf: file)).flatMap { try? jsonDecoder.decode(Team.self, from: $0) }?.name
            ?? URL(fileURLWithPath: path).lastPathComponent
    }

    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Mở dự án"
        panel.message = "Chọn thư mục dự án. Mỗi dự án có team và lịch sử chat riêng trong <dự án>/.agentteam."
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Opens a project in this window (replacing the current one, which is paused safely).
    func chooseWorkspace() {
        if let url = Self.pickFolder() { open(url) }
    }

    func open(_ url: URL) {
        let key = url.standardizedFileURL.path
        if key == orchestrator?.paths.workspace.standardizedFileURL.path { return }
        if let other = Self.liveOwner(key), other !== self {
            // Already open elsewhere: bring that window forward instead of opening it twice.
            other.window?.makeKeyAndOrderFront(nil)
            error = nil
            return
        }
        let r = runner
        final class Box { weak var o: Orchestrator? }
        let box = Box()
        do {
            let o = try Orchestrator(workspace: url) { chatId, req, cwd, onEvent in
                await r.run(chatId: chatId, request: req, cwd: cwd,
                            binaryPath: box.o?.team.binaryPaths[req.profile.provider.rawValue], onEvent: onEvent)
            }
            box.o = o
            o.cancelTurn = { r.cancel($0) }
            o.antigravityBinary = { r.binary(for: .antigravity, override: box.o?.team.binaryPaths[Provider.antigravity.rawValue]) }
            if let g = r.graphifyBinary() {
                let path = r.searchPath
                o.graphUpdater = { await ProcessRunner.updateGraph(binary: g, workspace: $0, path: path) }
            }
            close()
            Self.owners[key] = Owner(self)
            orchestrator = o
            if !o.isInstallCheck {
                o.refreshGraph()
                o.startInboxPolling()
                o.pump()
            }
            Self.recent = [key] + Self.recent.filter { $0 != key }
            error = nil
        } catch {
            self.error = "Không mở được \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func removeFromRecent(_ path: String) {
        Self.recent = Self.recent.filter { $0 != path }
        recentVersion += 1
    }

    /// Moves the project's `.agentteam` folder (team, chats, notes) to the Trash. Project files are never touched.
    func deleteProjectData() {
        guard let o = orchestrator else { return }
        let root = o.paths.root, key = o.paths.workspace.standardizedFileURL.path
        close()
        do {
            try FileManager.default.trashItem(at: root, resultingItemURL: nil)
            removeFromRecent(key)
        } catch {
            self.error = "Không xoá được \(root.path): \(error.localizedDescription)"
        }
    }

    /// Leaves the current project: its running turns are paused and requeued, resumed when it is reopened.
    func close() {
        guard let o = orchestrator else { return }
        o.suspend()
        let key = o.paths.workspace.standardizedFileURL.path
        if Self.owners[key]?.model === self { Self.owners[key] = nil }
        orchestrator = nil
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let o = model.orchestrator {
            MainView(o: o).id(o.paths.root)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "person.3.sequence").font(.system(size: 48)).foregroundStyle(.secondary)
                Text("Agent Team").font(.largeTitle.bold())
                Text("Chọn thư mục dự án. Mỗi dự án có team và lịch sử chat riêng trong <dự án>/.agentteam.\nMở thêm dự án song song: File → Mở dự án trong cửa sổ mới (⌘O).")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Mở dự án…") { model.chooseWorkspace() }.buttonStyle(.borderedProminent)
                let _ = model.recentVersion
                let recent = AppModel.recent.filter { FileManager.default.fileExists(atPath: $0) }
                if !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Gần đây").font(.caption).foregroundStyle(.secondary)
                        ForEach(recent, id: \.self) { p in
                            Button { model.open(URL(fileURLWithPath: p)) } label: {
                                HStack {
                                    Image(systemName: "folder")
                                    Text(AppModel.displayName(p)).bold()
                                    Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    if AppModel.liveOwner(p) != nil { Text("· đang mở — bấm để chuyển tới").font(.caption).foregroundStyle(.orange) }
                                }
                            }
                            .buttonStyle(.borderless)
                            .contextMenu { Button("Xoá khỏi danh sách") { model.removeFromRecent(p) } }
                        }
                    }
                    .frame(maxWidth: 520)
                }
                if let e = model.error { Text(e).foregroundStyle(.red) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension ChatStatus {
    var color: Color {
        switch self {
        case .idle: .gray
        case .queued: .yellow
        case .running: .blue
        case .done: .green
        case .failed: .red
        case .limited: .orange
        }
    }

    var title: String {
        switch self {
        case .idle: "rảnh"
        case .queued: "chờ"
        case .running: "đang chạy"
        case .done: "xong"
        case .failed: "lỗi"
        case .limited: "limit"
        }
    }
}
