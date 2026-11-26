// Window lists from the wslist helper process (Helper/main.swift says why it
// is a separate process). If the helper can't run, lists are fetched in this
// process on a background queue instead, which works but can make the bar
// pause while a window minimises.

import Foundation
import CoreGraphics

final class WindowLister {
    enum Kind: String { case onscreen, all }

    struct Reply {
        /// `.onscreen`: every on-screen window, front to back.
        var windows: [CGWin] = []
        /// `.all`: every window id on every Space.
        var ids: Set<CGWindowID> = []
        /// `.onscreen`: displays showing a full-screen app, and where each
        /// display's desktop sits in Mission Control (`SpaceState`).
        var fullScreen: Set<String> = []
        var positions: [String: Int] = [:]
        /// `.onscreen`: windows dropped for being on a desktop no display
        /// shows (mid-switch).
        var leftOut = 0
        /// How long the window server call itself took.
        var serverMs: Double = 0
        var viaHelper = true
    }

    private typealias Waiter = (kind: Kind, asked: UInt64, done: (Reply) -> Void)

    private let io = DispatchQueue(label: "dev.windowstrip.lister", qos: .userInteractive)
    private let fallbackQueue = DispatchQueue(label: "dev.windowstrip.cg", qos: .userInteractive)
    // Owned by `io`.
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextID = 0
    private var waiting: [Int: Waiter] = [:]
    private var launches: [UInt64] = []
    private var disabledUntil: UInt64 = 0
    private var launchedAt: UInt64 = 0

    static let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/wslist")
    /// A reply later than this means the helper is stuck: it is replaced.
    static let stuckAfter: Double = 3.0

    /// Calls `done` on the main thread.
    func request(_ kind: Kind, _ done: @escaping (Reply) -> Void) {
        io.async {
            if self.input == nil { self.launch() }
            guard let input = self.input else { self.fallback(kind, done); return }
            self.nextID += 1
            let id = self.nextID
            self.waiting[id] = (kind, uptimeNs(), done)
            do {
                try input.write(contentsOf: Data("\(id) \(kind.rawValue)\n".utf8))
            } catch {
                self.waiting[id] = nil
                self.lost("could not write to it (\(error.localizedDescription))")
                self.fallback(kind, done)
                return
            }
            self.io.asyncAfter(deadline: .now() + WindowLister.stuckAfter) {
                if self.waiting[id] != nil { self.lost("no answer to request \(id) in \(Int(WindowLister.stuckAfter)) s") }
            }
        }
    }

    // MARK: - The helper (io queue)

    private func launch() {
        let now = uptimeNs()
        guard now >= disabledUntil else { return }
        launches = launches.filter { now &- $0 < 60_000_000_000 } + [now]
        if launches.count > 5 {
            disabledUntil = now + 60_000_000_000
            Log.info("lister", "the helper failed 5 times in a minute; listing in-process for 60 s")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: WindowLister.helperURL.path) else {
            disabledUntil = .max
            Log.info("lister", "no helper at \(WindowLister.helperURL.path); listing in-process")
            return
        }
        let p = Process()
        p.executableURL = WindowLister.helperURL
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.nullDevice
        p.qualityOfService = .userInteractive
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.io.async { self?.received(data, from: p) }
        }
        p.terminationHandler = { [weak self] ended in
            self?.io.async { self?.ended(ended) }
        }
        do {
            try p.run()
        } catch {
            Log.info("lister", "could not start the helper: \(error.localizedDescription)")
            stdout.fileHandleForReading.readabilityHandler = nil
            return
        }
        process = p
        input = stdin.fileHandleForWriting
        buffer = Data()
        launchedAt = now
        Log.info("lister", "helper started (pid \(p.processIdentifier))")
    }

    private func received(_ data: Data, from p: Process) {
        guard p === process else { return }
        if data.isEmpty { return }   // end of file; `ended` handles it
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            answer(line)
        }
    }

    private func answer(_ line: String) {
        let fields = line.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
        guard fields.count == 6 else {
            Log.info("lister", "a reply from the helper had \(fields.count) fields, not 6")
            return
        }
        guard let id = Int(fields[0]), let w = waiting.removeValue(forKey: id) else { return }
        var reply = Reply()
        reply.serverMs = (Double(fields[1]) ?? 0) / 1000
        let spaces = SpaceState.parse(fullScreen: fields[2], positions: fields[3])
        reply.fullScreen = spaces.fullScreen
        reply.positions = spaces.positions
        reply.leftOut = Int(fields[4]) ?? 0
        switch w.kind {
        case .onscreen: reply.windows = WindowLister.parseWindows(fields[5])
        case .all: reply.ids = Set(fields[5].split(separator: ",").compactMap { CGWindowID($0) })
        }
        DispatchQueue.main.async { w.done(reply) }
    }

    static func parseWindows(_ body: Substring) -> [CGWin] {
        body.split(separator: "\u{1f}").compactMap { item in
            let f = item.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard f.count == 9, let id = CGWindowID(f[0]), let pid = pid_t(f[1]), let layer = Int(f[2]),
                  let alpha = Double(f[3]), let x = Double(f[4]), let y = Double(f[5]),
                  let width = Double(f[6]), let height = Double(f[7]) else { return nil }
            return CGWin(id: id, pid: pid, owner: String(f[8]), layer: layer, alpha: alpha,
                         frame: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    private func ended(_ p: Process) {
        guard p === process else { return }
        Log.info("lister", "helper exited (status \(p.terminationStatus)) after \(ms(msSince(launchedAt)))")
        drop(p)
    }

    /// The helper is unusable: replace it and answer its waiters in-process.
    private func lost(_ why: String) {
        guard let p = process else { return }
        Log.info("lister", "helper pid \(p.processIdentifier): \(why); restarting it")
        drop(p)
        p.terminate()
    }

    private func drop(_ p: Process) {
        (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        process = nil
        input = nil
        let orphans = waiting.values
        waiting = [:]
        for w in orphans { fallback(w.kind, w.done) }
    }

    private func fallback(_ kind: Kind, _ done: @escaping (Reply) -> Void) {
        fallbackQueue.async {
            let start = uptimeNs()
            var reply = Reply()
            reply.viaHelper = false
            switch kind {
            case .onscreen:
                let windows = onScreenWindows()
                let spaces = SpaceState.now()
                reply.windows = windows.filter { $0.layer != 0 || !spaces.elsewhere($0.id) }
                reply.leftOut = windows.count - reply.windows.count
                reply.fullScreen = spaces.fullScreen
                reply.positions = spaces.positions
            case .all:
                let all = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
                reply.ids = Set(all.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
            }
            reply.serverMs = msSince(start)
            DispatchQueue.main.async { done(reply) }
        }
    }
}
