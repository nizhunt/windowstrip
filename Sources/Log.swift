// Logging, timing and the main-thread stall watchdog.
//
// Log file: ~/Library/Logs/WindowStrip/WindowStrip.log (rolls over to
// WindowStrip.1.log at 8 MB). Lines look like
//   2026-01-01 12:00:00.000 [render] activate in 1.0ms: front #1234
// Detailed lines (every change to the bar, every AX notification) are on by default;
// `defaults write dev.windowstrip quiet -bool true` turns them off at the
// next launch.

import Foundation

/// Uptime clock in nanoseconds; the same clock in every process, so tests can
/// compare our timestamps with their own.
@inline(__always) func uptimeNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
@inline(__always) func msSince(_ start: UInt64) -> Double { Double(uptimeNs() &- start) / 1_000_000 }
func ms(_ value: Double) -> String { String(format: "%.1fms", value) }

enum Log {
    static let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/WindowStrip")
    static let fileURL = directory.appendingPathComponent("WindowStrip.log")
    static let previousURL = directory.appendingPathComponent("WindowStrip.1.log")
    static let maxBytes: UInt64 = 8 * 1024 * 1024

    /// Detailed lines. Read from any thread; written once at start.
    static var verbose = true

    private static let queue = DispatchQueue(label: "dev.windowstrip.log", qos: .utility)
    private static var handle: FileHandle?
    private static var size: UInt64 = 0
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func start() {
        verbose = !UserDefaults.standard.bool(forKey: "quiet")
        queue.sync { openFile() }
    }

    /// Always written.
    static func info(_ tag: String, _ message: String) { write(tag, message) }

    /// Written only in verbose mode; the message is not built otherwise.
    static func debug(_ tag: String, _ message: @autoclosure () -> String) {
        if verbose { write(tag, message()) }
    }

    /// Blocks until every queued line is on disk (used before exiting).
    static func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    private static func write(_ tag: String, _ message: String) {
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) [\(tag)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            if handle == nil { openFile() }
            try? handle?.write(contentsOf: data)
            size += UInt64(data.count)
            if size > maxBytes { rotate() }
        }
    }

    private static func openFile() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    private static func rotate() {
        try? handle?.close()
        try? FileManager.default.removeItem(at: previousURL)
        try? FileManager.default.moveItem(at: fileURL, to: previousURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        size = 0
    }
}

/// Notices when the main thread stops answering: a background timer posts a
/// block to the main queue every 50 ms and the block measures how late it ran.
/// One stall is reported once, with its full length.
final class StallWatchdog {
    struct Stall { let at: UInt64; let ms: Double }

    private let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
    private var lastReportedRun: UInt64 = 0          // main thread only
    private(set) var recent: [Stall] = []            // main thread only, newest last
    var thresholdMs: Double = 100

    func start() {
        timer.schedule(deadline: .now() + 2, repeating: .milliseconds(50), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            let posted = uptimeNs()
            DispatchQueue.main.async { self?.check(posted) }
        }
        timer.resume()
    }

    private func check(_ posted: UInt64) {
        let ran = uptimeNs()
        let late = Double(ran &- posted) / 1_000_000
        guard late >= thresholdMs else { return }
        if posted > lastReportedRun {
            recent.append(Stall(at: posted, ms: late))
            if recent.count > 50 { recent.removeFirst(recent.count - 50) }
            Log.info("stall", "main thread blocked \(ms(late)) (last slow step: \(Activity.lastSlow))")
        }
        lastReportedRun = ran
    }
}

/// Measures how long each pass of the main run loop stays busy, with no
/// timers or wake-ups of its own: a pass over 100 ms means the bar could not
/// react to the pointer for that long.
final class RunLoopStallMonitor {
    private var busySince: UInt64 = 0
    private(set) var recent: [StallWatchdog.Stall] = []
    private var observer: CFRunLoopObserver?

    func start() {
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        observer = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, 0) { [weak self] _, activity in
            guard let self else { return }
            if activity == .afterWaiting {
                self.busySince = uptimeNs()
            } else if self.busySince != 0 {
                let busy = msSince(self.busySince)
                let began = self.busySince
                self.busySince = 0
                if busy >= 100 {
                    self.recent.append(StallWatchdog.Stall(at: began, ms: busy))
                    if self.recent.count > 50 { self.recent.removeFirst(self.recent.count - 50) }
                    Log.info("stall", "main thread busy for \(ms(busy)) (last slow step: \(Activity.lastSlow))")
                }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }
}

/// Times a named step on the main thread and logs it when it is slow, so a
/// stall report can be traced to its cause. Main thread only.
enum Activity {
    static var lastSlow = "none"
    static let slowMs: Double = 25

    @discardableResult
    static func run<T>(_ name: String, _ body: () -> T) -> T {
        let start = uptimeNs()
        let result = body()
        let took = msSince(start)
        if took >= slowMs {
            lastSlow = "\(name) \(ms(took))"
            Log.info("slow", "\(name) took \(ms(took))")
        }
        return result
    }
}

/// Times the parts of one step, so a slow step's log line says which part
/// was slow ("cg 1.2ms, render 30.4ms").
struct Laps {
    let start = uptimeNs()
    private var mark: UInt64
    private var parts: [(String, Double)] = []
    init() { mark = start }
    mutating func lap(_ name: String) {
        let now = uptimeNs()
        parts.append((name, Double(now &- mark) / 1_000_000))
        mark = now
    }
    var totalMs: Double { msSince(start) }
    /// Parts of 0.5 ms or more.
    var summary: String {
        parts.filter { $0.1 >= 0.5 }.map { "\($0.0) \(ms($0.1))" }.joined(separator: ", ")
    }
}

/// Keeps the last `capacity` values for percentiles.
struct Ring {
    let capacity: Int
    private(set) var values: [Double] = []
    init(capacity: Int) { self.capacity = capacity }
    mutating func add(_ v: Double) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
    func percentile(_ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))
        return sorted[index]
    }
    var max: Double { values.max() ?? 0 }
}
