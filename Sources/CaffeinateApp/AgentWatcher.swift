import Foundation
import CoreServices

/// Notices Claude Code and Codex working: a transcript (.jsonl) write, or CPU in an agent's
/// process tree. The CPU check covers long tool calls (builds, tests) that write nothing until done.
final class AgentWatcher {
    static let grace: TimeInterval = 120  // counts as working if active this recently
    static let busyCPU = 5.0              // % across an agent's whole process tree

    private(set) var lastActivity: Date?
    var onActivity: (() -> Void)?
    private var stream: FSEventStreamRef?
    private var timer: Timer?

    var isWorking: Bool { lastActivity.map { Date().timeIntervalSince($0) < Self.grace } ?? false }

    deinit { stop() }

    /// Every Claude config dir (~/.claude, ~/.claude-work, ...) plus Codex.
    static func transcriptRoots(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let claude = names.filter { $0.hasPrefix(".claude") }.map { "\(home.path)/\($0)/projects" }
        return (claude + ["\(home.path)/.codex/sessions"]).filter { FileManager.default.fileExists(atPath: $0) }.sorted()
    }

    /// Total %CPU of every claude/codex process and all its descendants, from
    /// `ps -axo pid=,ppid=,%cpu=,comm=`.
    static func agentTreeCPU(psOutput: String) -> Double {
        var cpu: [Int32: Double] = [:]
        var children: [Int32: [Int32]] = [:]
        var stack: [Int32] = []
        for line in psOutput.split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard f.count == 4, let pid = Int32(f[0]), let ppid = Int32(f[1]), let c = Double(f[2]) else { continue }
            cpu[pid] = c
            children[ppid, default: []].append(pid)
            let name = f[3].split(separator: "/").last ?? ""
            if name == "claude" || name == "codex" { stack.append(pid) }
        }
        var seen = Set<Int32>()  // nested agents (subagents) would otherwise count twice
        var total = 0.0
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            total += cpu[pid] ?? 0
            stack += children[pid] ?? []
        }
        return total
    }

    func start() {
        guard timer == nil else { return }
        startStream()
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    private func mark() {
        lastActivity = Date()
        onActivity?()
    }

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = LidControl.run("/bin/ps", ["-axo", "pid=,ppid=,%cpu=,comm="]).output
            guard Self.agentTreeCPU(psOutput: out) >= Self.busyCPU else { return }
            DispatchQueue.main.async { self?.mark() }
        }
    }

    private func startStream() {
        let roots = Self.transcriptRoots()
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info, let list = unsafeBitCast(paths, to: NSArray.self) as? [String],
                  list.contains(where: { $0.hasSuffix(".jsonl") }) else { return }
            Unmanaged<AgentWatcher>.fromOpaque(info).takeUnretainedValue().mark()
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }
}
