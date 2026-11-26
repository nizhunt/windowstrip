// wstest: end-to-end tests for WindowStrip.
//
// Drives WSTestApp (tests/build/WSTestApp.app) over stdin/stdout, watches
// WindowStrip through ~/Library/Caches/dev.windowstrip/state.json, and checks
// focus and window order through the test app, CGWindowList and AX.
//
//   wstest [--only T04,T07] [--no-mouse] [--state <path>] [--log <path>] [--json <out>]
//   wstest --dump     parse state.json and the log, print what was read, exit
//   wstest --smoke    check the test app alone (no WindowStrip, no mouse)
//
// Latency is state.writtenAtUptimeNs minus the event's atUptimeNs (the same
// uptime clock in every process); "poll" is when this runner saw it.
//
// Mouse tests (T09-T12, T20, T21, T25, T26) only touch strip buttons whose pid is a test app this
// runner started, and only after an AX hit test puts WindowStrip's strip under
// the point. The cursor is put back and the test apps quit on every exit path
// (normal end, error, Ctrl-C, SIGTERM; the apps also quit when their stdin
// closes, so they die with the runner).

import AppKit
import ApplicationServices

// MARK: - Settings

enum Config {
    static let stripLevel = 26
    static let pollMs = 5.0
    /// After a limit passes, keep looking this long so a FAIL can say how late it was.
    static let graceMs = 1500.0
    static let setupTimeoutMs = 3000.0
    static let refreshNote = Notification.Name("dev.windowstrip.refresh")
    static let testBundleID = "dev.windowstrip.testapp"
    static let testAppName = "WSTestApp"
    static let dot = "\u{00B7}"
    /// Test windows in CG points, relative to the top-left of the notch screen.
    static let rects: [String: CGRect] = [
        "A": CGRect(x: 140, y: 220, width: 320, height: 200),
        "B": CGRect(x: 380, y: 300, width: 320, height: 200),
        "C": CGRect(x: 220, y: 380, width: 320, height: 200),
        "P": CGRect(x: 160, y: 430, width: 260, height: 140),
        "Z": CGRect(x: 470, y: 450, width: 200, height: 120),
        "S": CGRect(x: 200, y: 260, width: 320, height: 200),
        "D": CGRect(x: 300, y: 240, width: 320, height: 200),
        "E": CGRect(x: 520, y: 330, width: 300, height: 190),
    ]
}

// MARK: - Small helpers

@inline(__always) func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
@inline(__always) func ns(_ ms: Double) -> UInt64 { UInt64(max(0, ms) * 1_000_000) }
func msFrom(_ start: UInt64, to end: UInt64) -> Double { (Double(end) - Double(start)) / 1_000_000 }
func sleepMs(_ ms: Double) { if ms > 0 { usleep(useconds_t(ms * 1000)) } }
func msText(_ v: Double) -> String { v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v) }
func round1(_ v: Double) -> Double { v.isFinite ? (v * 10).rounded() / 10 : 0 }
func trim(_ v: Double) -> String {
    guard v.isFinite, abs(v) < 1e9 else { return "\(v)" }
    return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
}
func trim(_ v: CGFloat) -> String { trim(Double(v)) }
func pt(_ p: CGPoint) -> String { "(\(trim(p.x)), \(trim(p.y)))" }
func boxText(_ r: CGRect) -> String { "\(trim(r.minX)),\(trim(r.minY)) \(trim(r.width))x\(trim(r.height))" }
func out(_ line: String) { print(line); fflush(stdout) }
func warn(_ line: String) { FileHandle.standardError.write((line + "\n").data(using: .utf8)!) }
func expandPath(_ path: String) -> String {
    let p = NSString(string: path).expandingTildeInPath
    return p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
}
/// An optional as a JSON value: the value, or null.
func orNull<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? NSNull() }
func appName(_ pid: Int32) -> String { NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)" }

struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

// MARK: - state.json

/// An uptime in nanoseconds. Accepts integers, and floats to be lenient.
struct Nanos: Decodable {
    let value: UInt64
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(UInt64.self) { value = v; return }
        let d = try c.decode(Double.self)
        value = d > 0 ? UInt64(d) : 0
    }
}

struct Box: Decodable {
    let x: Double, y: Double, w: Double, h: Double
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    var text: String { boxText(rect) }
}

struct StripButton: Decodable {
    let windowId: UInt32
    let pid: Int32
    let app: String?
    let front: Bool?
    let hovered: Bool?
    let frame: Box
}

struct StripPanel: Decodable {
    let display: UInt32?
    let windowNumber: Int?
    let level: Int
    let frame: Box
    let iconAreaMaxX: Double?
    let buttons: [StripButton]
}

struct TooltipState: Decodable {
    let visible: Bool
    let windowId: UInt32?
    let text: String?
    let chars: Int?
}

struct NeighbourState: Decodable {
    let windowId: UInt32?
    let owner: String?
    let pid: Int32?
    let layer: Int?
    let frame: Box?
    let closed: Bool?
}

struct RaiseState: Decodable {
    let windowId: UInt32?
    let requestedAtUptimeNs: Nanos?
    let result: String?
    let ms: Double?
}

struct StallState: Decodable {
    let atUptimeNs: Nanos
    let ms: Double
}

struct StripState: Decodable {
    let version: Int
    let engine: String?
    let pid: Int32
    let writtenAtUptimeNs: Nanos
    let trusted: Bool?
    let panels: [StripPanel]
    let tooltip: TooltipState?
    let neighbours: [NeighbourState]?
    let lastRaise: RaiseState?
    let recentRefreshMs: [Double]?
    let stalls: [StallState]?
    let desktopRepairs: Int?

    var written: UInt64 { writtenAtUptimeNs.value }
    var buttons: [StripButton] { panels.flatMap(\.buttons) }
    func button(_ id: UInt32) -> StripButton? { buttons.first { $0.windowId == id } }
    func has(_ id: UInt32) -> Bool { button(id) != nil }
    func panel(holding id: UInt32) -> StripPanel? { panels.first { $0.buttons.contains { $0.windowId == id } } }
    var frontIds: [UInt32] { buttons.filter { $0.front == true }.map(\.windowId) }
    var tipVisible: Bool { tooltip?.visible == true }
    func tipShows(_ id: UInt32) -> Bool { tipVisible && tooltip?.windowId == id }
    var tipText: String {
        guard let t = tooltip else { return "no tooltip object" }
        return "visible \(t.visible), windowId \(t.windowId.map(String.init) ?? "-"), text \(t.text.map { "'\($0)'" } ?? "null")"
    }
}

func describe(_ error: Error) -> String {
    guard let e = error as? DecodingError else { return "\(error)" }
    func path(_ keys: [CodingKey]) -> String {
        let p = keys.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
        return p.hasPrefix(".") ? String(p.dropFirst()) : (p.isEmpty ? "top level" : p)
    }
    switch e {
    case .keyNotFound(let key, let c): return "missing key \(path(c.codingPath + [key]))"
    case .typeMismatch(let type, let c): return "wrong type at \(path(c.codingPath)), expected \(type)"
    case .valueNotFound(let type, let c): return "null at \(path(c.codingPath)), expected \(type)"
    case .dataCorrupted(let c): return "invalid JSON at \(path(c.codingPath)): \(c.debugDescription)"
    @unknown default: return "\(e)"
    }
}

/// Reads state.json, decoding again only when the file changed.
final class StateReader {
    let path: String
    private var key: [Int64] = []
    private(set) var latest: StripState?
    private(set) var problem: String? = "not read yet"

    init(path: String) { self.path = path }

    /// The current state, or nil when the file is missing or does not parse (see `problem`).
    @discardableResult
    func read() -> StripState? {
        var st = stat()
        guard stat(path, &st) == 0 else { problem = "missing (\(path))"; key = []; return nil }
        let k = [Int64(st.st_ino), Int64(st.st_size), Int64(st.st_mtimespec.tv_sec), Int64(st.st_mtimespec.tv_nsec)]
        if k == key, let latest { return latest }
        guard let data = FileManager.default.contents(atPath: path) else { problem = "unreadable"; return nil }
        do {
            let state = try JSONDecoder().decode(StripState.self, from: data)
            latest = state
            key = k
            problem = nil
            return state
        } catch {
            problem = "does not parse: \(describe(error))"
            return nil
        }
    }
}

// MARK: - WindowStrip.log

struct LogLine {
    let date: Date
    let tag: String
    let message: String
    let text: String
}

/// Lines look like `2026-01-01 12:00:00.000 [tag] message`.
final class LogReader {
    let path: String
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init(path: String) { self.path = path }

    func size() -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    func parse(_ line: String) -> LogLine? {
        let chars = Array(line)
        guard chars.count >= 27, chars[23] == " ", chars[24] == "[" else { return nil }
        guard let date = formatter.date(from: String(chars[0..<23])) else { return nil }
        guard let close = chars[25...].firstIndex(of: "]"), close > 25 else { return nil }
        let tag = String(chars[25..<close])
        guard !tag.contains(" ") else { return nil }
        var start = close + 1
        if start < chars.count, chars[start] == " " { start += 1 }
        return LogLine(date: date, tag: tag, message: String(chars[start...]), text: line)
    }

    /// Lines written since byte `offset` (from the start if the log rolled over),
    /// reading at most `maxBytes` from the end.
    func lines(since offset: UInt64, maxBytes: UInt64 = 256 * 1024) -> (parsed: [LogLine], unparsed: Int) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], 0) }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        var start = offset <= end ? offset : 0
        var cut = false
        if end - start > maxBytes { start = end - maxBytes; cut = true }
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        var raw = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        if cut, !raw.isEmpty { raw.removeFirst() }      // started mid-line
        var parsed: [LogLine] = []
        var unparsed = 0
        for r in raw {
            if let line = parse(String(r)) { parsed.append(line) } else { unparsed += 1 }
        }
        return (parsed, unparsed)
    }
}

// MARK: - Screens, CGWindowList, AX

func displayID(_ screen: NSScreen) -> UInt32? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}
/// AppKit's origin is the bottom-left of the primary screen, CG's its top-left.
func flipHeight() -> CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
func cgRect(of screen: NSScreen) -> CGRect {
    CGRect(x: screen.frame.minX, y: flipHeight() - screen.frame.maxY, width: screen.frame.width, height: screen.frame.height)
}
func notchScreens() -> [NSScreen] { NSScreen.screens.filter { $0.safeAreaInsets.top > 0 } }

struct CGWin {
    let id: UInt32
    let pid: Int32
    let owner: String
    let layer: Int
    let alpha: Double
    let bounds: CGRect
    var label: String { "\(owner) #\(id)" }
}

/// On-screen windows of every layer, front to back.
func cgWindows() -> [CGWin] {
    guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
    return info.compactMap { w in
        guard let id = w[kCGWindowNumber as String] as? UInt32,
              let pid = w[kCGWindowOwnerPID as String] as? Int32,
              let dict = w[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
        return CGWin(id: id, pid: pid, owner: w[kCGWindowOwnerName as String] as? String ?? "?",
                     layer: w[kCGWindowLayer as String] as? Int ?? 0,
                     alpha: w[kCGWindowAlpha as String] as? Double ?? 1, bounds: bounds)
    }
}

/// The front-most ordinary window: layer 0, visible, not a tiny helper.
func frontLayer0(_ list: [CGWin] = cgWindows()) -> CGWin? {
    list.first { $0.layer == 0 && $0.alpha > 0 && $0.bounds.width >= 20 && $0.bounds.height >= 20 }
}

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
}

func axWindows(_ pid: Int32) -> [(id: UInt32, element: AXUIElement)] {
    guard let list = axValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AXUIElement] else { return [] }
    return list.compactMap { element in
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success ? (id, element) : nil
    }
}

/// Subrole (or "no subrole") of each AX window of `pid`, by window number.
func axSubroles(_ pid: Int32) -> [UInt32: String] {
    var result: [UInt32: String] = [:]
    for (id, element) in axWindows(pid) {
        result[id] = axValue(element, kAXSubroleAttribute) as? String ?? "no subrole"
    }
    return result
}

enum Hit {
    case element(pid: Int32, role: String?)
    case failed(AXError)
}

func axHitTest(_ p: CGPoint) -> Hit {
    var element: AXUIElement?
    let err = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &element)
    guard err == .success, let element else { return .failed(err) }
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    return .element(pid: pid, role: axValue(element, kAXRoleAttribute) as? String)
}

func frontmostPid() -> Int32? {
    if let value = axValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute),
       CFGetTypeID(value) == AXUIElementGetTypeID() {
        var pid: pid_t = 0
        if AXUIElementGetPid(value as! AXUIElement, &pid) == .success { return pid }
    }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier
}

func frontmostText() -> String { frontmostPid().map { "\(appName($0)) (pid \($0))" } ?? "unknown" }

// MARK: - Mouse

enum Mouse {
    static var saved: CGPoint?
    static var buttonDown = false
    static let source = CGEventSource(stateID: .hidSystemState)

    static func location() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func post(_ type: CGEventType, at p: CGPoint) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                                  mouseButton: .left) else { return }
        if type == .leftMouseDown || type == .leftMouseUp { event.setIntegerValueField(.mouseEventClickState, value: 1) }
        event.post(tap: .cghidEventTap)
        if type == .leftMouseDown { buttonDown = true }
        if type == .leftMouseUp { buttonDown = false }
    }

    /// Remembers where the cursor is, once per test.
    static func save() { if saved == nil { saved = location() } }

    static func move(to p: CGPoint) { post(.mouseMoved, at: p) }

    /// Releases a held button and puts the cursor back where `save` found it.
    static func restore() {
        if buttonDown { post(.leftMouseUp, at: location()) }
        guard let p = saved else { return }
        post(.mouseMoved, at: p)
        usleep(20_000)
        let now = location()
        if abs(now.x - p.x) > 1 || abs(now.y - p.y) > 1 { CGWarpMouseCursorPosition(p) }
        saved = nil
    }
}

// MARK: - Test app client

/// Lines from the test app's stdout, filled by a reader thread.
final class LineQueue {
    private var lines: [String] = []
    private var closed = false
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)

    func push(_ line: String) { lock.lock(); lines.append(line); lock.unlock(); signal.signal() }
    func close() { lock.lock(); closed = true; lock.unlock(); signal.signal() }
    func drain() { lock.lock(); lines.removeAll(); lock.unlock() }

    func pop(timeoutMs: Double) -> String? {
        let deadline = DispatchTime.now() + .nanoseconds(Int(ns(timeoutMs)))
        while true {
            lock.lock()
            if !lines.isEmpty { let line = lines.removeFirst(); lock.unlock(); return line }
            if closed { lock.unlock(); return nil }
            lock.unlock()
            if signal.wait(timeout: deadline) == .timedOut { return nil }
        }
    }
}

struct AppStatus {
    struct Window { let number: UInt32; let visible: Bool; let miniaturized: Bool }
    let active: Bool
    let hidden: Bool
    let keyTag: String?
    let mainTag: String?
    let keySinceNs: UInt64
    let windows: [String: Window]
}

final class TestApp {
    let name: String
    let pid: Int32
    private let process: Process
    private let input: Pipe
    private let output: Pipe
    private let replies = LineQueue()

    init(name: String, executable: String, stderrPath: String) throws {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw HarnessError("test app not built at \(executable); run tests/run-tests.sh")
        }
        self.name = name
        process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        input = Pipe()
        output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        FileManager.default.createFile(atPath: stderrPath, contents: nil)
        process.standardError = FileHandle(forWritingAtPath: stderrPath) ?? FileHandle.nullDevice
        try process.run()
        pid = process.processIdentifier
        Emergency.add(pid)

        let handle = output.fileHandleForReading
        let queue = replies
        let reader = Thread {
            var buffer = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    queue.push(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            queue.close()
        }
        reader.name = "\(name) stdout"
        reader.start()
    }

    var isRunning: Bool { process.isRunning }

    /// Sends one command and returns its reply; throws on timeout or "ok":false.
    @discardableResult
    func send(_ command: String, timeoutMs: Double = 3000) throws -> [String: Any] {
        guard process.isRunning else { throw HarnessError("\(name) is not running") }
        replies.drain()                     // a late reply to an earlier, timed-out command
        let sentAt = nowNs()
        let bytes = Array((command + "\n").utf8)
        let fd = input.fileHandleForWriting.fileDescriptor
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n < 0 {
                if errno == EINTR { continue }
                throw HarnessError("\(name): cannot write '\(command)': \(String(cString: strerror(errno)))")
            }
            offset += n
        }
        let cmd = command.split(separator: " ").first.map(String.init) ?? ""
        let deadline = nowNs() + ns(timeoutMs)
        while true {
            let left = msFrom(nowNs(), to: deadline)
            guard left > 0, let line = replies.pop(timeoutMs: left) else {
                let state = process.isRunning ? "" : " (it exited with status \(process.terminationStatus))"
                throw HarnessError("\(name): no reply to '\(command)' within \(trim(timeoutMs)) ms\(state)")
            }
            guard let reply = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  reply["cmd"] as? String == cmd else { continue }
            if let at = reply["atUptimeNs"] as? NSNumber, at.uint64Value < sentAt { continue }   // stale
            guard reply["ok"] as? Bool == true else {
                throw HarnessError("\(name): '\(command)' failed: \(reply["error"] ?? "no error text")")
            }
            return reply
        }
    }

    /// The reply's atUptimeNs (falls back to now).
    func at(_ reply: [String: Any]) -> UInt64 { (reply["atUptimeNs"] as? NSNumber)?.uint64Value ?? nowNs() }

    func status(timeoutMs: Double = 1000) throws -> AppStatus {
        let r = try send("status", timeoutMs: timeoutMs)
        var windows: [String: AppStatus.Window] = [:]
        for w in r["windows"] as? [[String: Any]] ?? [] {
            guard let tag = w["tag"] as? String else { continue }
            windows[tag] = AppStatus.Window(number: (w["windowNumber"] as? NSNumber)?.uint32Value ?? 0,
                                            visible: w["visible"] as? Bool ?? false,
                                            miniaturized: w["miniaturized"] as? Bool ?? false)
        }
        return AppStatus(active: r["active"] as? Bool ?? false, hidden: r["hidden"] as? Bool ?? false,
                         keyTag: r["keyTag"] as? String, mainTag: r["mainTag"] as? String,
                         keySinceNs: (r["keySinceNs"] as? NSNumber)?.uint64Value ?? 0, windows: windows)
    }

    func waitForExit(_ ms: Double) -> Bool {
        let end = nowNs() + ns(ms)
        while process.isRunning && nowNs() < end { sleepMs(10) }
        return !process.isRunning
    }

    /// Quits politely, then escalates. Safe to call twice.
    func shutdown() {
        if process.isRunning { _ = try? send("quit", timeoutMs: 1000) }
        if !waitForExit(1500) { process.terminate() }
        if !waitForExit(500) { kill(pid, SIGKILL); _ = waitForExit(500) }
        try? input.fileHandleForWriting.close()
        Emergency.remove(pid)
    }
}

// MARK: - Emergency cleanup (signals, watchdog)

enum Emergency {
    private static let lock = NSLock()
    private static var pids: [Int32] = []

    static func add(_ pid: Int32) { lock.lock(); pids.append(pid); lock.unlock() }
    static func remove(_ pid: Int32) { lock.lock(); pids.removeAll { $0 == pid }; lock.unlock() }

    /// Cursor back, test apps gone. Only pids that are still test apps are signalled.
    static func run() {
        Mouse.restore()
        lock.lock()
        let list = pids
        lock.unlock()
        let ours = list.filter { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier == Config.testBundleID }
        ours.forEach { kill($0, SIGTERM) }
        if !ours.isEmpty { usleep(400_000) }
        ours.filter { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier == Config.testBundleID }
            .forEach { kill($0, SIGKILL) }
    }
}

/// Crash path: best effort only. The test apps also quit when our pipes close.
func crashCleanup() {
    if Mouse.buttonDown, let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                         mouseCursorPosition: Mouse.location(), mouseButton: .left) {
        e.post(tap: .cghidEventTap)
    }
    if let p = Mouse.saved { CGWarpMouseCursorPosition(p) }
}

var signalSources: [DispatchSourceSignal] = []

func installSignalHandlers() {
    signal(SIGPIPE, SIG_IGN)
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
        source.setEventHandler {
            warn("\nwstest: signal \(sig), restoring the cursor and quitting the test apps")
            Emergency.run()
            exit(128 + sig)
        }
        source.resume()
        signalSources.append(source)
    }
    for sig in [SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE] {
        signal(sig) { s in
            crashCleanup()
            signal(s, SIG_DFL)
            raise(s)
        }
    }
}

// MARK: - Results

enum Status: String { case pass = "PASS", fail = "FAIL", skip = "SKIP", inconclusive = "INCONCLUSIVE" }

struct Outcome {
    var status: Status
    var timing: String? = nil       // shown in parentheses on PASS
    var detail: String = ""
    var metrics: [String: Any] = [:]

    static func pass(_ timing: String? = nil, _ detail: String = "", _ metrics: [String: Any] = [:]) -> Outcome {
        Outcome(status: .pass, timing: timing, detail: detail, metrics: metrics)
    }
    static func fail(_ reason: String, _ metrics: [String: Any] = [:]) -> Outcome {
        Outcome(status: .fail, detail: reason, metrics: metrics)
    }
    static func skip(_ reason: String) -> Outcome { Outcome(status: .skip, detail: reason) }
    static func inconclusive(_ reason: String, _ metrics: [String: Any] = [:]) -> Outcome {
        Outcome(status: .inconclusive, detail: reason, metrics: metrics)
    }
}

struct TestCase {
    let id: String
    let name: String
    let mouse: Bool
    let body: (Harness) throws -> Outcome
    init(_ id: String, _ name: String, mouse: Bool = false, _ body: @escaping (Harness) throws -> Outcome) {
        self.id = id; self.name = name; self.mouse = mouse; self.body = body
    }
}

struct TestResult {
    let test: TestCase
    let outcome: Outcome
    let durationMs: Double
    let log: [String]

    var line: String {
        let o = outcome
        switch o.status {
        case .pass:
            var s = "PASS \(test.id) \(test.name)"
            if let t = o.timing { s += " (\(t))" }
            if !o.detail.isEmpty { s += " \(o.detail)" }
            return s
        default:
            return "\(o.status.rawValue) \(test.id) \(test.name): \(o.detail)"
        }
    }
}

// MARK: - Timed expectations

enum Probe {
    /// Judged on state.json writes made at or after the event; latency = writtenAtUptimeNs - event.
    case state((StripState) -> Bool)
    /// Judged by the runner (test app, CGWindowList); latency = when the runner saw it.
    case live(() -> Bool)
}

struct Expect {
    let label: String
    let event: UInt64
    let limitMs: Double
    let probe: Probe
    init(_ label: String, _ event: UInt64, _ limitMs: Double, _ probe: Probe) {
        self.label = label; self.event = event; self.limitMs = limitMs; self.probe = probe
    }
    var isState: Bool { if case .state = probe { return true }; return false }
}

struct Seen {
    var latencyMs: Double?
    var pollMs: Double?
    var state: StripState?
}

/// Formats the latencies of a set of expectations, and finds the misses.
struct Report {
    var timing: String
    var problems: [String]
    var metrics: [String: Any]

    init(_ expects: [Expect], _ seen: [Seen], required: Set<String>? = nil) {
        var parts: [String] = [], polls: [String] = [], problems: [String] = []
        var metrics: [String: Any] = [:]
        let single = expects.count == 1
        for (e, s) in zip(expects, seen) {
            var m: [String: Any] = ["limitMs": e.limitMs]
            if let l = s.latencyMs {
                parts.append(single ? msText(l) : "\(e.label) \(msText(l))")
                m["latencyMs"] = round1(l)
                if e.isState, let p = s.pollMs { polls.append(trim(round1(p))); m["pollMs"] = round1(p) }
            } else {
                parts.append(single ? "not seen" : "\(e.label) not seen")
            }
            metrics[e.label] = m
            guard required?.contains(e.label) ?? true else { continue }
            if let l = s.latencyMs {
                if l > e.limitMs { problems.append("\(e.label) took \(msText(l)) (limit \(trim(e.limitMs)) ms)") }
            } else {
                problems.append("\(e.label) not seen within \(trim(e.limitMs + Config.graceMs)) ms")
            }
        }
        timing = parts.joined(separator: ", ") + (polls.isEmpty ? "" : "; poll \(polls.joined(separator: "/")) ms")
        self.problems = problems
        self.metrics = metrics
    }

    var ok: Bool { problems.isEmpty }

    func outcome(_ extra: String = "") -> Outcome {
        if ok { return .pass(timing, extra, metrics) }
        return .fail(problems.joined(separator: "; ") + " [\(timing)]" + (extra.isEmpty ? "" : " \(extra)"), metrics)
    }
}

// MARK: - Options

struct Options {
    var only: [String]? = nil
    var noMouse = false
    var statePath = expandPath("~/Library/Caches/dev.windowstrip/state.json")
    var logPath = expandPath("~/Library/Logs/WindowStrip/WindowStrip.log")
    var jsonPath: String? = nil
    var dump = false
    var smoke = false

    static let usage = """
    usage: wstest [--only T04,T07] [--no-mouse] [--state <path>] [--log <path>] [--json <out>]
           wstest --dump     parse state.json and the log, print what was read
           wstest --smoke    open and close one test app window, no WindowStrip needed
    """

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        func value(_ flag: String) -> String {
            i += 1
            guard i < args.count else { warn("\(flag) needs a value\n\(usage)"); exit(2) }
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--only": o.only = parseIDs(value(a))
            case "--no-mouse": o.noMouse = true
            case "--state": o.statePath = expandPath(value(a))
            case "--log": o.logPath = expandPath(value(a))
            case "--json": o.jsonPath = expandPath(value(a))
            case "--dump": o.dump = true
            case "--smoke": o.smoke = true
            case "-h", "--help": print(usage); exit(0)
            default:
                if a.hasPrefix("--only=") { o.only = parseIDs(String(a.dropFirst(7))) }
                else { warn("unknown option \(a)\n\(usage)"); exit(2) }
            }
            i += 1
        }
        return o
    }

    static func parseIDs(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == " " }).map { raw in
            let digits = raw.uppercased().drop(while: { $0 == "T" })
            guard let n = Int(digits), (1...27).contains(n) else { warn("unknown test '\(raw)'"); exit(2) }
            return String(format: "T%02d", n)
        }
    }
}

// MARK: - Harness

final class Win {
    let tag: String
    let app: TestApp
    let number: UInt32
    let openedAt: UInt64
    var title: String
    init(tag: String, app: TestApp, number: UInt32, openedAt: UInt64, title: String) {
        self.tag = tag; self.app = app; self.number = number; self.openedAt = openedAt; self.title = title
    }
}

struct Activation {
    let ok: Bool
    let at: UInt64          // when the activation that worked was requested
    let via: String
}

final class Harness {
    let opts: Options
    let reader: StateReader
    let log: LogReader
    let runStartNs = nowNs()
    let runStartDate = Date()
    let buildDir: String
    let testAppPath: String
    /// Top-left of the notch screen in CG points; test windows go there.
    let origin: CGPoint
    var wins: [String: Win] = [:]
    var apps: [String: TestApp] = [:]
    private var launchFailure: String?

    init(_ opts: Options) {
        self.opts = opts
        reader = StateReader(path: opts.statePath)
        log = LogReader(path: opts.logPath)
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
        buildDir = exe.deletingLastPathComponent().path
        testAppPath = ProcessInfo.processInfo.environment["WSTEST_APP"]
            ?? buildDir + "/WSTestApp.app/Contents/MacOS/WSTestApp"
        origin = notchScreens().first.map { cgRect(of: $0).origin } ?? .zero
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
    }

    var testPids: Set<Int32> { Set(apps.values.filter(\.isRunning).map(\.pid)) }

    var mouseSkipReason: String? {
        if opts.noMouse { return "--no-mouse" }
        if !AXIsProcessTrusted() { return "this terminal has no Accessibility permission, so events cannot be posted" }
        if !CGPreflightPostEventAccess() { return "this process may not post events" }
        return nil
    }

    /// Checked once before the first test that needs state.json (T01 reports on its own).
    lazy var stateProblem: String? = {
        if reader.read() != nil { return nil }
        if settle(after: 0, timeoutMs: 3000, { _ in true }) != nil { return nil }
        return reader.problem ?? "unreadable"
    }()

    func postRefresh() {
        DistributedNotificationCenter.default().postNotificationName(Config.refreshNote, object: nil,
                                                                     userInfo: nil, deliverImmediately: true)
    }

    func state() throws -> StripState {
        guard let s = reader.read() else { throw HarnessError("state.json \(reader.problem ?? "unreadable")") }
        return s
    }

    /// A state written after `after` if one comes within `timeoutMs` (pokes WindowStrip once), else the newest.
    func freshState(timeoutMs: Double = 1000) throws -> StripState {
        let t = nowNs()
        postRefresh()
        if let s = settle(after: t, timeoutMs: timeoutMs, pokeEveryMs: nil, { _ in true }) { return s }
        return try state()
    }

    // MARK: Waiting

    func pollUntil(_ ms: Double, everyMs: Double = 10, _ condition: () -> Bool) -> Bool {
        let end = nowNs() + ns(ms)
        while true {
            if condition() { return true }
            if nowNs() >= end { return false }
            sleepMs(everyMs)
        }
    }

    /// Unmeasured wait for a precondition. While it does not hold, pokes
    /// WindowStrip with the refresh notification (unless `pokeEveryMs` is nil).
    /// After a poke it waits 150 ms before returning, so the refresh it asked
    /// for cannot land inside the measured step that follows.
    func settle(after: UInt64, timeoutMs: Double = Config.setupTimeoutMs, pokeEveryMs: Double? = 400,
                _ predicate: (StripState) -> Bool) -> StripState? {
        let start = nowNs()
        var nextPoke = start
        var lastPoke: UInt64?
        while true {
            if let s = reader.read(), s.written >= after, predicate(s) {
                if let p = lastPoke { while nowNs() < p + ns(150) { sleepMs(Config.pollMs) } }
                return s
            }
            let now = nowNs()
            if now >= start + ns(timeoutMs) { return nil }
            if let every = pokeEveryMs, now >= nextPoke { postRefresh(); lastPoke = now; nextPoke = now + ns(every) }
            sleepMs(Config.pollMs)
        }
    }

    /// Polls every 5 ms until every expectation is met, or until the latest
    /// limit plus the grace period has passed.
    func watch(_ expects: [Expect], graceMs: Double = Config.graceMs) -> [Seen] {
        var seen = Array(repeating: Seen(), count: expects.count)
        let deadline = expects.map { $0.event + ns($0.limitMs + graceMs) }.max() ?? nowNs()
        while true {
            let state = reader.read()
            for (i, e) in expects.enumerated() where seen[i].latencyMs == nil {
                switch e.probe {
                case .state(let predicate):
                    if let s = state, s.written >= e.event, predicate(s) {
                        seen[i] = Seen(latencyMs: msFrom(e.event, to: s.written), pollMs: msFrom(e.event, to: nowNs()), state: s)
                    }
                case .live(let predicate):
                    if predicate() {
                        let l = msFrom(e.event, to: nowNs())
                        seen[i] = Seen(latencyMs: l, pollMs: l, state: nil)
                    }
                }
            }
            if seen.allSatisfy({ $0.latencyMs != nil }) || nowNs() >= deadline { return seen }
            sleepMs(Config.pollMs)
        }
    }

    // MARK: Test apps and windows

    func app(_ name: String) throws -> TestApp {
        if let a = apps[name], a.isRunning { return a }
        if let failure = launchFailure { throw HarnessError(failure) }
        try? FileManager.default.createDirectory(atPath: buildDir + "/logs", withIntermediateDirectories: true)
        var started: TestApp?
        do {
            let a = try TestApp(name: name, executable: testAppPath, stderrPath: buildDir + "/logs/\(name).stderr.log")
            started = a
            _ = try a.status(timeoutMs: 10_000)        // answers once its run loop is up
            apps[name] = a
            wins = wins.filter { $0.value.app.isRunning }
            return a
        } catch {
            started?.shutdown()
            launchFailure = "test app \(name) did not start: \(error)"
            throw HarnessError(launchFailure!)
        }
    }

    var runningApps: [TestApp] { ["app1", "app2"].compactMap { apps[$0] }.filter(\.isRunning) }

    @discardableResult
    func open(_ tag: String, kind: String = "standard", rect: CGRect? = nil, in app: TestApp) throws -> Win {
        let r = (rect ?? Config.rects[tag]!).offsetBy(dx: origin.x, dy: origin.y)
        let reply = try app.send("open \(tag) \(kind) \(trim(r.minX)) \(trim(r.minY)) \(trim(r.width)) \(trim(r.height))")
        guard let number = (reply["windowNumber"] as? NSNumber)?.uint32Value, number > 0 else {
            throw HarnessError("open \(tag): reply has no windowNumber")
        }
        let win = Win(tag: tag, app: app, number: number, openedAt: app.at(reply), title: "WSTest \(tag)")
        wins[tag] = win
        return win
    }

    func close(_ tag: String) {
        guard let w = wins.removeValue(forKey: tag) else { return }
        _ = try? w.app.send("close \(tag)")
    }

    /// Window `tag`, opened if needed; with `shown`, also waits (unmeasured) for its button.
    func ensure(_ tag: String, in app: TestApp, shown: Bool) throws -> Win {
        let win: Win
        if let w = wins[tag], w.app === app, app.isRunning { win = w } else { win = try open(tag, in: app) }
        if shown, settle(after: 0, { $0.has(win.number) }) == nil {
            throw HarnessError("setup: \(tag) (#\(win.number)) never appeared in the strip (\(reader.problem ?? "state.json readable"))")
        }
        return win
    }

    /// Makes `app` the active app: first it may already be (or become) active on
    /// its own; else the runner sets kAXFrontmost on it.
    func makeActive(_ app: TestApp, event: UInt64) -> Activation {
        if pollUntil(150, { (try? app.status())?.active == true }) { return Activation(ok: true, at: event, via: "app") }
        let t = nowNs()
        let err = AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.pid),
                                               kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if pollUntil(1000, { (try? app.status())?.active == true }) { return Activation(ok: true, at: t, via: "AX") }
        return Activation(ok: false, at: event, via: "AX set frontmost returned \(err.rawValue)")
    }

    func notActive(_ app: TestApp, _ act: Activation) -> String {
        "\(app.name) could not be made active (\(act.via); frontmost is \(frontmostText()))"
    }

    // MARK: Mouse, behind safety checks

    /// Centre of `win`'s strip button, after checking that it is safe to touch:
    /// the button is a running test app's, and AX (or, if AX cannot answer, the
    /// CG window order) puts WindowStrip's strip under that point.
    func target(_ win: Win) throws -> CGPoint {
        let s = try state()
        guard let panel = s.panel(holding: win.number), let button = s.button(win.number) else {
            throw HarnessError("\(win.tag) (#\(win.number)) has no button in the strip")
        }
        guard testPids.contains(button.pid), button.pid == win.app.pid else {
            throw HarnessError("refusing to touch button #\(button.windowId): pid \(button.pid) is not a test app")
        }
        let p = CGPoint(x: button.frame.rect.midX, y: button.frame.rect.midY)
        guard panel.frame.rect.insetBy(dx: -0.5, dy: -0.5).contains(p) else {
            throw HarnessError("\(win.tag)'s button centre \(pt(p)) is outside the strip \(panel.frame.text)")
        }
        switch axHitTest(p) {
        case .element(let pid, _) where pid == s.pid:
            return p
        case .element(let pid, let role):
            throw HarnessError("not touching \(win.tag)'s button at \(pt(p)): \(appName(pid)) (pid \(pid), \(role ?? "?")) is on top there")
        case .failed(let err):
            if let top = cgWindows().first(where: { $0.alpha > 0 && $0.bounds.contains(p) }), top.pid == s.pid { return p }
            throw HarnessError("not touching \(win.tag)'s button at \(pt(p)): AX hit test failed (\(err.rawValue)) and the top CG window there is not WindowStrip's")
        }
    }

    /// Moves onto `win`'s button and clicks; returns the uptime right before
    /// mouse-down (WindowStrip acts on mouse-down). The cursor is restored
    /// before returning.
    func click(_ win: Win) throws -> UInt64 {
        let p = try target(win)
        Mouse.save()
        defer { Mouse.restore() }
        Mouse.move(to: p)
        sleepMs(40)
        guard let s = reader.read(), let b = s.button(win.number), b.frame.rect.contains(p) else {
            throw HarnessError("\(win.tag)'s button moved before the click; nothing clicked")
        }
        let downAt = nowNs()
        Mouse.post(.leftMouseDown, at: p)
        sleepMs(30)
        Mouse.post(.leftMouseUp, at: p)
        return downAt
    }

    func hover(_ win: Win) throws -> UInt64 {
        let p = try target(win)
        Mouse.save()
        Mouse.move(to: p)
        return nowNs()
    }

    /// Where the cursor goes when it leaves the strip: back where it was, unless
    /// that is on or near a strip; then the middle of window A or a fixed spot.
    func awayPoint() -> CGPoint {
        let strips = (reader.latest?.panels ?? []).map { $0.frame.rect.insetBy(dx: -40, dy: -60) }
        if let p = Mouse.saved, !strips.contains(where: { $0.contains(p) }) { return p }
        if let a = wins["A"], let w = cgWindows().first(where: { $0.id == a.number }) {
            return CGPoint(x: w.bounds.midX, y: w.bounds.midY)
        }
        return CGPoint(x: origin.x + 300, y: origin.y + 160)
    }

    func moveAway() -> UInt64 {
        Mouse.move(to: awayPoint())
        return nowNs()
    }

    /// Cursor away from the strip and the tooltip gone (unmeasured). A hidden
    /// tooltip in an older write counts: leaving cannot make it appear.
    func clearHover() {
        Mouse.move(to: awayPoint())
        _ = settle(after: 0, timeoutMs: 1000) { !$0.tipVisible }
    }

    // MARK: Running

    func run(_ test: TestCase) -> TestResult {
        let start = nowNs()
        let logOffset = log.size()
        var outcome: Outcome
        if test.mouse, let reason = mouseSkipReason {
            outcome = .skip(reason)
        } else if test.id != "T01", let problem = stateProblem {
            outcome = .fail("state.json \(problem)")
        } else {
            do { outcome = try test.body(self) } catch { outcome = .fail("\(error)") }
        }
        Mouse.restore()
        var lines: [String] = []
        if outcome.status == .fail || outcome.status == .inconclusive {
            lines = log.lines(since: logOffset).parsed.suffix(40).map(\.text)
        }
        return TestResult(test: test, outcome: outcome, durationMs: msFrom(start, to: nowNs()), log: lines)
    }

    func cleanup() {
        Mouse.restore()
        for app in apps.values { app.shutdown() }
        apps = [:]
        wins = [:]
    }

    func forgetApps() { apps = [:]; wins = [:] }

    func header() -> String {
        var parts: [String] = []
        if let s = reader.read() {
            let age = msFrom(s.written, to: nowNs()) / 1000
            parts.append("WindowStrip pid \(s.pid)\(s.engine.map { " (\($0) engine)" } ?? ""), state.json written \(String(format: "%.1f", age)) s ago")
            if !notchScreens().isEmpty, !cgWindows().contains(where: { $0.pid == s.pid && $0.layer > 0 && $0.alpha > 0 }) {
                parts.append("the strip is NOT on screen (a full-screen Space?), so most tests will fail")
            }
        } else {
            parts.append("state.json \(reader.problem ?? "unreadable")")
        }
        parts.append(AXIsProcessTrusted() ? "runner has Accessibility" : "runner has NO Accessibility")
        return "# " + parts.joined(separator: "; ")
    }
}

// MARK: - Tests

extension Harness {
    static let tests: [TestCase] = [
        TestCase("T01", "strip-present") { try $0.t01() },
        TestCase("T02", "trusted") { try $0.t02() },
        TestCase("T03", "notch-neighbour") { try $0.t03() },
        TestCase("T04", "appear") { try $0.t04() },
        TestCase("T05", "front") { try $0.t05() },
        TestCase("T06", "panel-borderless-hidden") { try $0.t06() },
        TestCase("T07", "second-window") { try $0.t07() },
        TestCase("T08", "focus-front") { try $0.t08() },
        TestCase("T09", "click-raise", mouse: true) { try $0.t09() },
        TestCase("T10", "cross-app-raise", mouse: true) { try $0.t10() },
        TestCase("T11", "hover", mouse: true) { try $0.t11() },
        TestCase("T12", "title-update", mouse: true) { try $0.t12() },
        TestCase("T13", "minimize") { try $0.t13() },
        TestCase("T14", "hide-app") { try $0.t14() },
        TestCase("T15", "close") { try $0.t15() },
        TestCase("T16", "quit") { try $0.t16() },
        TestCase("T19", "desktop-switch") { try $0.t19() },
        TestCase("T20", "resting-pointer", mouse: true) { try $0.t20() },
        TestCase("T21", "hung-app", mouse: true) { try $0.t21() },
        TestCase("T22", "overflow") { try $0.t22() },
        TestCase("T25", "raise-z-order", mouse: true) { try $0.t25() },
        TestCase("T26", "late-raise", mouse: true) { try $0.t26() },
        TestCase("T27", "full-screen") { try $0.t27() },
        TestCase("T28", "every-desktop") { try $0.t28() },
        TestCase("T23", "soak") { try $0.t23() },
        // Last: these read the whole run, then WindowStrip is restarted.
        TestCase("T17", "stalls") { try $0.t17() },
        TestCase("T18", "refresh-p95") { try $0.t18() },
        TestCase("T24", "restart-under-island") { try $0.t24() },
    ]

    /// T01: a fresh write after the refresh notification; level 26; the frame is the notch strip.
    func t01() throws -> Outcome {
        let t0 = nowNs()
        postRefresh()
        guard let s = settle(after: t0, timeoutMs: 5000, pokeEveryMs: nil, { _ in true }) else {
            let old = reader.latest.map { "; newest write is \(String(format: "%.1f", msFrom($0.written, to: nowNs()) / 1000)) s old" } ?? ""
            return .fail("state.json not written within 5 s of the refresh notification (\(reader.problem ?? "no fresh write")\(old))")
        }
        var problems: [String] = []
        if s.version != 2 { problems.append("version \(s.version), expected 2") }
        if kill(s.pid, 0) != 0 { problems.append("pid \(s.pid) is not running") }
        let screens = notchScreens()
        guard !screens.isEmpty else { return .skip("no screen has a notch (safeAreaInsets.top is 0 on all)") }
        let onScreen = cgWindows()
        var found: [String] = []
        for screen in screens {
            let id = displayID(screen) ?? 0
            let sf = cgRect(of: screen)
            guard let width = screen.auxiliaryTopLeftArea?.width else { problems.append("display \(id) has no auxiliaryTopLeftArea"); continue }
            let expected = CGRect(x: sf.minX, y: sf.minY, width: width, height: screen.safeAreaInsets.top)
            guard let panel = s.panels.first(where: { $0.display == id })
                    ?? s.panels.first(where: { $0.frame.rect.intersects(sf) }) else {
                problems.append("no panel for notch display \(id)")
                continue
            }
            if panel.level != Config.stripLevel { problems.append("display \(id): level \(panel.level), expected \(Config.stripLevel)") }
            let f = panel.frame.rect
            if abs(f.minX - expected.minX) > 1 || abs(f.minY - expected.minY) > 1
                || abs(f.width - expected.width) > 1 || abs(f.height - expected.height) > 1 {
                problems.append("display \(id): frame \(panel.frame.text), expected \(boxText(expected)) (±1)")
            }
            if let number = panel.windowNumber {
                if let w = onScreen.first(where: { $0.id == UInt32(number) }) {
                    if w.layer != panel.level { problems.append("window #\(number) is on CG layer \(w.layer), state says \(panel.level)") }
                } else {
                    problems.append("panel window #\(number) is not on screen in CGWindowList")
                }
            }
            found.append("display \(id) level \(panel.level) frame \(panel.frame.text)")
        }
        if !problems.isEmpty { return .fail(problems.joined(separator: "; ")) }
        return .pass(msText(msFrom(t0, to: s.written)), found.joined(separator: "; "))
    }

    /// T02: WindowStrip has Accessibility.
    func t02() throws -> Outcome {
        let s = try state()
        switch s.trusted {
        case true?: return .pass()
        case false?: return .fail("trusted is false: WindowStrip has no Accessibility permission")
        case nil: return .fail("state.json has no 'trusted' field")
        }
    }

    /// T03: another app's window over the strip at our level or above (e.g. Vorssaint's island).
    func t03() throws -> Outcome {
        let s = try freshState()
        let windows = cgWindows()
        var checked: [String] = []
        var problems: [String] = []
        for panel in s.panels {
            let strip = panel.frame.rect
            let panelIndex = panel.windowNumber.flatMap { n in windows.firstIndex { $0.id == UInt32(n) } }
            let neighbours = windows.filter { w in
                let overlap = w.bounds.intersection(strip)
                return w.pid != s.pid && w.layer >= panel.level && w.alpha > 0
                    && !overlap.isNull && overlap.width > 0 && overlap.height > 0
            }
            for n in neighbours {
                var notes: [String] = []
                // 1. A strip-height neighbour keeps the icons 4 pt clear.
                if n.bounds.height <= strip.height + 4 {
                    let limit = n.bounds.minX - 4
                    let rightmost = panel.buttons.map { $0.frame.rect.maxX }.max()
                    let over = panel.buttons.filter { $0.frame.rect.maxX > limit + 0.01 }
                    if over.isEmpty {
                        notes.append("icons clear (rightmost \(rightmost.map { trim($0) } ?? "none"), limit \(trim(limit)))")
                    } else {
                        problems.append("\(n.label): \(over.count) button(s) end past x \(trim(limit)) (rightmost \(trim(rightmost ?? 0)))")
                    }
                } else {
                    notes.append("taller than the strip (h \(trim(n.bounds.height))), icon check not applied")
                }
                // 2. It is above the strip.
                let index = windows.firstIndex { $0.id == n.id }
                if n.layer > panel.level {
                    notes.append("above (layer \(n.layer))")
                } else if let index, let panelIndex {
                    if index < panelIndex { notes.append("above in CG order") }
                    else { problems.append("\(n.label) is below the strip in the CG order (\(index) vs strip \(panelIndex))") }
                } else {
                    problems.append("strip window #\(panel.windowNumber.map(String.init) ?? "?") is not in CGWindowList")
                }
                // 3. The mouse reaches it.
                let p = CGPoint(x: n.bounds.minX + 8, y: strip.midY)
                switch axHitTest(p) {
                case .element(let pid, _) where pid == n.pid:
                    notes.append("AX hit at \(pt(p)) is \(n.owner)")
                case .element(let pid, let role):
                    problems.append("AX hit test at \(pt(p)) returned \(appName(pid)) (pid \(pid), \(role ?? "?")), not \(n.owner)")
                case .failed(let err):
                    problems.append("AX hit test at \(pt(p)) failed (\(err.rawValue))")
                }
                if s.neighbours?.contains(where: { $0.windowId == n.id }) != true { notes.append("missing from state.neighbours") }
                checked.append("\(n.label) x \(trim(n.bounds.minX))-\(trim(n.bounds.maxX)) h \(trim(n.bounds.height)): \(notes.joined(separator: ", "))")
            }
        }
        if checked.isEmpty { return .skip("no other app's window at layer >= \(Config.stripLevel) overlaps the strip") }
        if !problems.isEmpty { return .fail(problems.joined(separator: "; ") + " [\(checked.joined(separator: "; "))]") }
        return .pass(nil, checked.joined(separator: "; "))
    }

    /// When CGWindowList first listed a window (watched alongside), so a slow
    /// result can be split into the window server's share and WindowStrip's.
    func listed(_ win: Win) -> Expect {
        Expect("listed", win.openedAt, 400, .live { cgWindows().contains { $0.id == win.number } })
    }

    func listedText(_ seen: Seen) -> String {
        seen.latencyMs.map { "(CG listed the window after \(msText($0)))" } ?? "(CG never listed the window)"
    }

    /// T04: a new standard window appears.
    func t04() throws -> Outcome {
        let app = try app("app1")
        let a = try open("A", in: app)
        let appear = Expect("appear", a.openedAt, 400, .state { $0.has(a.number) })
        let seen = watch([appear, listed(a)])
        return Report([appear], [seen[0]]).outcome(listedText(seen[1]))
    }

    /// T05: A is the front button.
    func t05() throws -> Outcome {
        let app = try app("app1")
        let a = try ensure("A", in: app, shown: false)
        let act = makeActive(app, event: a.openedAt)
        guard act.ok else { return .inconclusive(notActive(app, act)) }
        let e = [Expect("front", act.at, 400, .state { $0.frontIds == [a.number] })]
        let seen = watch(e)
        var extra = act.via == "AX" ? "(made active through AX)" : ""
        if seen[0].latencyMs == nil, let s = reader.latest { extra += " front ids \(s.frontIds)" }
        return Report(e, seen).outcome(extra)
    }

    /// T06: a floating panel and a borderless window never get a button.
    func t06() throws -> Outcome {
        let app = try app("app1")
        let p = try open("P", kind: "panel", in: app)
        let z = try open("Z", kind: "borderless", in: app)
        defer { close("P"); close("Z") }
        let start = min(p.openedAt, z.openedAt)
        let end = start + ns(1500)
        var pokes: [Double] = [200, 900]
        var writes = Set<UInt64>()
        var appeared: [String: Double] = [:]
        var subroles: [UInt32: String] = [:]
        while nowNs() < end {
            let elapsed = msFrom(start, to: nowNs())
            if let first = pokes.first, elapsed >= first { postRefresh(); pokes.removeFirst() }
            if subroles.isEmpty, elapsed >= 300 { subroles = axSubroles(app.pid) }
            if let s = reader.read(), s.written >= start {
                writes.insert(s.written)
                for w in [p, z] where appeared[w.tag] == nil && s.has(w.number) {
                    appeared[w.tag] = msFrom(start, to: s.written)
                }
            }
            sleepMs(Config.pollMs)
        }
        if subroles.isEmpty { subroles = axSubroles(app.pid) }
        let cg = cgWindows()
        func info(_ w: Win) -> String {
            let layer = cg.first { $0.id == w.number }.map { "layer \($0.layer)" } ?? "NOT on screen"
            return "\(w.tag) #\(w.number) \(layer), \(subroles[w.number] ?? "not in AXWindows")"
        }
        let detail = "\(info(p)); \(info(z))"
        let metrics: [String: Any] = ["P": ["subrole": orNull(subroles[p.number])],
                                      "Z": ["subrole": orNull(subroles[z.number])], "writes": writes.count]
        if !appeared.isEmpty {
            let list = appeared.sorted { $0.key < $1.key }.map { "\($0.key) after \(msText($0.value))" }
            return .fail("shown in the strip: \(list.joined(separator: ", ")) [\(detail)]", metrics)
        }
        if writes.isEmpty { return .inconclusive("no state.json write in the 1.5 s window [\(detail)]", metrics) }
        if !cg.contains(where: { $0.id == p.number }) || !cg.contains(where: { $0.id == z.number }) {
            return .inconclusive("a test window was not on screen, so its absence proves nothing [\(detail)]", metrics)
        }
        return .pass("1500 ms", "\(detail); \(writes.count) writes checked", metrics)
    }

    /// T07: a second standard window appears and becomes front.
    func t07() throws -> Outcome {
        let app = try app("app1")
        _ = try ensure("A", in: app, shown: false)
        let b = try open("B", in: app)
        let act = makeActive(app, event: b.openedAt)
        var e = [Expect("appear", b.openedAt, 400, .state { $0.has(b.number) })]
        if act.ok { e.append(Expect("front", act.at, 400, .state { $0.frontIds == [b.number] })) }
        var seen = watch(e + [listed(b)])
        let cg = listedText(seen.removeLast())
        let report = Report(e, seen)
        if !act.ok {
            return report.ok ? .inconclusive("appeared (\(report.timing)) but \(notActive(app, act)) \(cg)", report.metrics)
                             : report.outcome("\(notActive(app, act)) \(cg)")
        }
        return report.outcome((act.via == "AX" ? "(made active through AX) " : "") + cg)
    }

    /// T08: `focus A` moves the front highlight to A.
    func t08() throws -> Outcome {
        let app = try app("app1")
        let a = try ensure("A", in: app, shown: true)
        let b = try ensure("B", in: app, shown: true)
        if reader.read()?.frontIds != [b.number] {
            let r = try app.send("focus B")
            let setup = makeActive(app, event: app.at(r))
            guard setup.ok else { return .inconclusive(notActive(app, setup)) }
            guard settle(after: app.at(r), { $0.frontIds == [b.number] }) != nil else {
                return .fail("setup: B never became the front button after 'focus B'")
            }
        }
        let r = try app.send("focus A")
        let act = makeActive(app, event: app.at(r))
        guard act.ok else { return .inconclusive(notActive(app, act)) }
        let e = [Expect("front", act.at, 300, .state { $0.frontIds == [a.number] })]
        return Report(e, watch(e)).outcome(act.via == "AX" ? "(made active through AX)" : "")
    }

    /// Shared by T09 and T10: click A's button, then watch key, CG order and the strip.
    private func clickRaise(_ a: Win, _ app: TestApp) throws -> Outcome {
        let clickAt = try click(a)
        let e = [
            Expect("key", clickAt, 400, .live { (try? app.status(timeoutMs: 500)).map { $0.active && $0.keyTag == a.tag } == true }),
            Expect("CG front", clickAt, 400, .live { frontLayer0()?.id == a.number }),
            Expect("strip front", clickAt, 400, .state { $0.frontIds == [a.number] }),
        ]
        var seen = watch(e)
        // The app knows when A became key; use that over the poll time.
        if let st = try? app.status(), st.active, st.keyTag == a.tag, st.keySinceNs >= clickAt, seen[0].latencyMs != nil {
            seen[0].latencyMs = msFrom(clickAt, to: st.keySinceNs)
        }
        let report = Report(e, seen, required: ["key", "CG front"])
        var extra: [String] = []
        if seen[1].latencyMs == nil, let f = frontLayer0() { extra.append("front window is \(f.label)") }
        if let raise = reader.latest?.lastRaise, raise.windowId == a.number {
            extra.append("lastRaise \(raise.result ?? "?")\(raise.ms.map { " " + msText($0) } ?? "")")
        }
        return report.outcome(extra.joined(separator: ", "))
    }

    /// T09: with B in front, clicking A's icon makes A key and front.
    func t09() throws -> Outcome {
        let app = try app("app1")
        let a = try ensure("A", in: app, shown: true)
        let b = try ensure("B", in: app, shown: true)
        let r = try app.send("focus B")
        let act = makeActive(app, event: app.at(r))
        guard act.ok else { return .inconclusive(notActive(app, act)) }
        guard settle(after: app.at(r), { $0.frontIds == [b.number] }) != nil else {
            return .fail("setup: B never became the front button after 'focus B'")
        }
        guard (try? app.status())?.keyTag == "B" else { return .fail("setup: B is not key after 'focus B'") }
        return try clickRaise(a, app)
    }

    /// T10: with another app (test app 2, window C) in front, clicking A's icon raises A.
    func t10() throws -> Outcome {
        let app1 = try app("app1")
        let a = try ensure("A", in: app1, shown: true)
        let app2 = try app("app2")
        let c = try ensure("C", in: app2, shown: true)
        let r = try app2.send("focus C")
        let act = makeActive(app2, event: app2.at(r))
        guard act.ok else { return .inconclusive(notActive(app2, act)) }
        guard settle(after: app2.at(r), { $0.frontIds == [c.number] }) != nil else {
            return .fail("setup: C never became the front button")
        }
        guard (try? app1.status())?.active == false else { return .fail("setup: test app 1 is still active with C in front") }
        return try clickRaise(a, app1)
    }

    /// T11: hover A, then B, then leave; the tooltip follows.
    func t11() throws -> Outcome {
        let app = try app("app1")
        let a = try ensure("A", in: app, shown: true)
        let b = try ensure("B", in: app, shown: true)
        Mouse.save()
        defer { Mouse.restore() }
        clearHover()

        let textA = "\(Config.testAppName) \(Config.dot) \(a.title)"
        let t0 = try hover(a)
        let showA = Expect("show A", t0, 250, .state { $0.tipShows(a.number) && $0.tooltip?.text == textA })
        let seenA = watch([showA])
        guard seenA[0].latencyMs != nil else {
            let now = reader.latest?.tipText ?? "no state"
            let r = Report([showA], seenA)
            return .fail(r.problems.joined(separator: "; ") + " (expected '\(textA)'; tooltip is \(now))", r.metrics)
        }

        // A to B: sample every write and note any hidden tooltip in between.
        let t1 = try hover(b)
        var flickerAt: Double?
        var switched: (latency: Double, poll: Double, written: UInt64)?
        var last: UInt64 = 0
        let end = t1 + ns(250 + Config.graceMs)
        while nowNs() < end {
            if let s = reader.read(), s.written >= t1, s.written != last {
                last = s.written
                if s.tipShows(b.number) { switched = (msFrom(t1, to: s.written), msFrom(t1, to: nowNs()), s.written); break }
                if !s.tipVisible, flickerAt == nil { flickerAt = msFrom(t1, to: s.written) }
            }
            sleepMs(Config.pollMs)
        }
        // Then it should stay on B while the cursor rests there.
        var leftB: Double?
        if let sw = switched {
            let until = nowNs() + ns(150)
            while nowNs() < until {
                if let s = reader.read(), s.written > sw.written, !s.tipShows(b.number) { leftB = msFrom(t1, to: s.written); break }
                sleepMs(Config.pollMs)
            }
        }

        let t2 = moveAway()
        let hide = Expect("hide", t2, 300, .state { !$0.tipVisible })
        let seenHide = watch([hide])

        var problems: [String] = []
        var parts = ["show A \(msText(seenA[0].latencyMs!))"]
        if let sw = switched {
            parts.append("switch to B \(msText(sw.latency))")
            if sw.latency > 250 { problems.append("switch to B took \(msText(sw.latency)) (limit 250 ms)") }
        } else {
            problems.append("tooltip never switched to B within \(trim(250 + Config.graceMs)) ms (tooltip is \(reader.latest?.tipText ?? "?"))")
        }
        if let l = leftB { problems.append("tooltip left B \(msText(l)) after the move while the cursor stayed on B") }
        if let l = seenHide[0].latencyMs {
            parts.append("hide \(msText(l))")
            if l > 300 { problems.append("hide took \(msText(l)) (limit 300 ms)") }
        } else {
            problems.append("tooltip still visible \(trim(300 + Config.graceMs)) ms after leaving")
        }
        let flicker = flickerAt.map { "flicker: hidden at \(msText($0)) between A and B" } ?? "flicker: none seen"
        let metrics: [String: Any] = ["showA": round1(seenA[0].latencyMs!), "switchB": orNull(switched.map { round1($0.latency) }),
                                      "hide": orNull(seenHide[0].latencyMs.map(round1)),
                                      "flickerMs": orNull(flickerAt.map(round1))]
        if !problems.isEmpty { return .fail(problems.joined(separator: "; ") + " [\(parts.joined(separator: ", "))] \(flicker)", metrics) }
        return .pass(parts.joined(separator: ", "), flicker, metrics)
    }

    /// T12: after a title change, hovering shows the new title.
    func t12() throws -> Outcome {
        let app = try app("app1")
        let a = try ensure("A", in: app, shown: true)
        let original = a.title
        try app.send("title A New Title")
        a.title = "New Title"
        defer { _ = try? app.send("title A \(original)"); a.title = original }
        Mouse.save()
        defer { Mouse.restore() }
        clearHover()
        let expected = "\(Config.testAppName) \(Config.dot) New Title"
        let t0 = try hover(a)
        let e = [Expect("text", t0, 500, .state { $0.tipShows(a.number) && $0.tooltip?.text == expected })]
        let seen = watch(e)
        let tooltip = reader.latest?.tipText ?? "no state"
        _ = moveAway()
        let report = Report(e, seen)
        return report.ok ? report.outcome() : report.outcome("(expected '\(expected)'; tooltip is \(tooltip))")
    }

    /// T13: minimize removes A; deminimize brings it back.
    func t13() throws -> Outcome {
        let app = try app("app1")
        let a = try ensure("A", in: app, shown: true)
        let r1 = try app.send("minimize A")
        let gone = Expect("gone", app.at(r1), 500, .state { !$0.has(a.number) })
        let s1 = watch([gone])
        _ = pollUntil(2000) { (try? app.status())?.windows["A"]?.miniaturized == true }
        // The icon can go before the minimise animation ends; a restore sent
        // during the animation waits for it, so wait until A has left the
        // window server's on-screen list.
        _ = pollUntil(2000, everyMs: 20) { !cgWindows().contains { $0.id == a.number } }
        let r2 = try app.send("deminimize A")
        let back = Expect("back", app.at(r2), 600, .state { $0.has(a.number) })
        let s2 = watch([back])
        return Report([gone, back], s1 + s2).outcome()
    }

    /// T14: hiding the app removes all its buttons; unhiding restores them.
    func t14() throws -> Outcome {
        let app = try app("app1")
        _ = try ensure("A", in: app, shown: true)
        _ = try ensure("B", in: app, shown: true)
        let before = try state().buttons.filter { $0.pid == app.pid }.map(\.windowId)
        guard !before.isEmpty else { return .fail("setup: the test app has no buttons before hiding") }
        let r1 = try app.send("hide")
        let gone = Expect("gone", app.at(r1), 500, .state { s in !s.buttons.contains { $0.pid == app.pid } })
        let s1 = watch([gone])
        _ = pollUntil(2000) { (try? app.status())?.hidden == true }
        let r2 = try app.send("unhide")
        let back = Expect("back", app.at(r2), 600, .state { s in before.allSatisfy { s.has($0) } })
        let s2 = watch([back])
        return Report([gone, back], s1 + s2).outcome("(\(before.count) buttons)")
    }

    /// T15: closing B removes it.
    func t15() throws -> Outcome {
        let app = try app("app1")
        let b = try ensure("B", in: app, shown: true)
        let r = try app.send("close B")
        wins["B"] = nil
        let e = [Expect("gone", app.at(r), 400, .state { !$0.has(b.number) })]
        return Report(e, watch(e)).outcome()
    }

    /// T16: quitting the test apps removes their buttons.
    func t16() throws -> Outcome {
        var list = runningApps
        if list.isEmpty {
            let app = try app("app1")
            _ = try ensure("A", in: app, shown: true)
            list = [app]
        }
        let pids = Set(list.map(\.pid))
        guard settle(after: 0, { s in s.buttons.contains { pids.contains($0.pid) } }) != nil else {
            return .fail("setup: no buttons for the running test apps before quitting")
        }
        var first: UInt64?
        for app in list {
            if let r = try? app.send("quit", timeoutMs: 2000) { first = min(first ?? .max, app.at(r)) }
        }
        let event = first ?? nowNs()
        let e = [Expect("gone", event, 500, .state { s in !s.buttons.contains { pids.contains($0.pid) } })]
        let seen = watch(e)
        let stuck = list.filter { !$0.waitForExit(2000) }
        for app in list { app.shutdown() }
        forgetApps()
        let extra = "(\(list.count) app\(list.count == 1 ? "" : "s"))" + (stuck.isEmpty ? "" : " \(stuck.count) did not exit by itself")
        return Report(e, seen).outcome(extra)
    }

    /// T17: no main-thread stall of 100 ms or more since the run started.
    func t17() throws -> Outcome {
        let s = try freshState()
        guard let stalls = s.stalls else { return .fail("state.json has no 'stalls' field") }
        let ours = stalls.filter { $0.atUptimeNs.value >= runStartNs && $0.ms >= 100 }
        let worst = ours.map(\.ms).max() ?? 0
        let metrics: [String: Any] = ["count": ours.count, "maxMs": round1(worst)]
        let text = "\(ours.count) stall\(ours.count == 1 ? "" : "s") >= 100 ms, max \(msText(worst))"
        return ours.isEmpty ? .pass(nil, text, metrics) : .fail(text, metrics)
    }

    /// T18: refresh p95 at most 8 ms.
    func t18() throws -> Outcome {
        let s = try freshState()
        guard let samples = s.recentRefreshMs else { return .fail("state.json has no 'recentRefreshMs' field") }
        guard !samples.isEmpty else { return .inconclusive("recentRefreshMs is empty") }
        let sorted = samples.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int((p * Double(sorted.count)).rounded(.up)) - 1))] }
        let p50 = pct(0.5), p95 = pct(0.95), worst = sorted.last!
        let text = "p50 \(msText(p50)), p95 \(msText(p95)), max \(msText(worst)) over \(sorted.count) refreshes"
        let metrics: [String: Any] = ["p50": round1(p50), "p95": round1(p95), "max": round1(worst), "n": sorted.count]
        return p95 <= 8 ? .pass(nil, text, metrics) : .fail("\(text); p95 limit 8 ms", metrics)
    }
}

// MARK: - --dump and --smoke

extension Harness {
    func dump() -> Int32 {
        var ok = true
        out("state: \(reader.path)")
        if let s = reader.read() {
            let age = msFrom(s.written, to: nowNs()) / 1000
            out("  version \(s.version), engine \(s.engine ?? "-"), pid \(s.pid), trusted \(s.trusted.map(String.init) ?? "missing"), written \(String(format: "%.1f", age)) s ago")
            for p in s.panels {
                out("  panel display \(p.display.map(String.init) ?? "-") window #\(p.windowNumber.map(String.init) ?? "-") level \(p.level) frame \(p.frame.text) iconAreaMaxX \(p.iconAreaMaxX.map { trim($0) } ?? "-") buttons \(p.buttons.count)")
                for b in p.buttons {
                    out("    #\(b.windowId) pid \(b.pid) \(b.app ?? "?")\(b.front == true ? " FRONT" : "") \(b.frame.text)")
                }
            }
            out("  tooltip: \(s.tipText)\(s.tooltip?.chars.map { ", chars \($0)" } ?? "")")
            for n in s.neighbours ?? [] {
                out("  neighbour #\(n.windowId.map(String.init) ?? "-") \(n.owner ?? "?") pid \(n.pid.map(String.init) ?? "-") layer \(n.layer.map(String.init) ?? "-") \(n.frame?.text ?? "-")\(n.closed.map { $0 ? " closed" : " open" } ?? "")")
            }
            if let r = s.lastRaise {
                out("  lastRaise: #\(r.windowId.map(String.init) ?? "-") \(r.result ?? "-") \(r.ms.map { msText($0) } ?? "-")")
            }
            let refresh = (s.recentRefreshMs ?? []).sorted()
            if !refresh.isEmpty {
                let pct = { (p: Double) in refresh[min(refresh.count - 1, max(0, Int((p * Double(refresh.count)).rounded(.up)) - 1))] }
                out("  refresh: n \(refresh.count), p50 \(msText(pct(0.5))), p95 \(msText(pct(0.95))), max \(msText(refresh.last!))")
            } else {
                out("  refresh: \(s.recentRefreshMs == nil ? "field missing" : "no samples")")
            }
            let stalls = s.stalls ?? []
            let recent = stalls.filter { $0.atUptimeNs.value >= nowNs() &- ns(600_000) }
            out("  stalls: \(stalls.count) listed, \(recent.count) in the last 10 min, max \(msText(stalls.map(\.ms).max() ?? 0))")
        } else {
            out("  \(reader.problem ?? "unreadable")")
            ok = false
        }
        out("log: \(log.path)")
        let (lines, unparsed) = log.lines(since: 0)
        if lines.isEmpty && unparsed == 0 {
            out("  no lines (missing or empty)")
        } else {
            var counts: [String: Int] = [:]
            lines.forEach { counts[$0.tag, default: 0] += 1 }
            out("  \(lines.count) lines parsed, \(unparsed) not in the expected format (last 256 KB)")
            out("  tags: " + counts.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
            for l in lines.suffix(5) { out("  [\(l.tag)] \(l.message)") }
        }
        return ok ? 0 : 1
    }

    /// The test app alone: launch, open one standard window, see it in CGWindowList
    /// and AX, close it, see it go, quit.
    func smoke() -> Int32 {
        var failed = false
        func report(_ ok: Bool, _ text: String) { out("\(ok ? "PASS" : "FAIL") \(text)"); if !ok { failed = true } }
        defer { cleanup() }
        do {
            let app = try app("app1")
            report(true, "launch: pid \(app.pid)")
            let w = try open("S", in: app)
            let requested = Config.rects["S"]!.offsetBy(dx: origin.x, dy: origin.y)
            var found: CGWin?
            _ = pollUntil(3000, everyMs: 5) { found = cgWindows().first { $0.id == w.number }; return found != nil }
            guard let cg = found else { report(false, "appear: window #\(w.number) not in CGWindowList after 3 s"); return 1 }
            let latency = msFrom(w.openedAt, to: nowNs())
            let sameBox = abs(cg.bounds.minX - requested.minX) <= 1 && abs(cg.bounds.minY - requested.minY) <= 1
                && abs(cg.bounds.width - requested.width) <= 1 && abs(cg.bounds.height - requested.height) <= 1
            report(cg.pid == app.pid && cg.layer == 0 && sameBox,
                   "appear: #\(w.number) on screen within \(msText(latency)), layer \(cg.layer), owner \(cg.owner) pid \(cg.pid), bounds \(boxText(cg.bounds)) (asked \(boxText(requested)))")
            if AXIsProcessTrusted() {
                let element = axWindows(app.pid).first { $0.id == w.number }?.element
                let subrole = element.flatMap { axValue($0, kAXSubroleAttribute) as? String } ?? "not in AXWindows"
                let title = element.flatMap { axValue($0, kAXTitleAttribute) as? String } ?? "-"
                report(subrole == "AXStandardWindow" && title == "WSTest S", "ax: subrole \(subrole), title '\(title)'")
            }
            let st = try app.status()
            out("INFO status: active \(st.active), key \(st.keyTag ?? "none"), main \(st.mainTag ?? "none"), windows \(st.windows.keys.sorted())")
            let r = try app.send("close S")
            wins["S"] = nil
            let closedAt = app.at(r)
            let gone = pollUntil(3000, everyMs: 5) { !cgWindows().contains { $0.id == w.number } }
            report(gone, gone ? "close: #\(w.number) left CGWindowList within \(msText(msFrom(closedAt, to: nowNs())))"
                             : "close: #\(w.number) still on screen 3 s after close")
            let q = try app.send("quit")
            let exited = app.waitForExit(3000)
            report(exited, exited ? "quit: exited \(msText(msFrom(app.at(q), to: nowNs()))) after quit" : "quit: still running 3 s after quit")
        } catch {
            report(false, "\(error)")
        }
        return failed ? 1 : 0
    }
}

// MARK: - Main

installSignalHandlers()
let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
let harness = Harness(options)

if options.dump { exit(harness.dump()) }
if options.smoke { exit(harness.smoke()) }

// The whole run must never hang with the cursor or the test apps held.
let watchdog = DispatchSource.makeTimerSource(queue: .global())
watchdog.schedule(deadline: .now() + 600)
watchdog.setEventHandler {
    out("FAIL harness: the run took more than 600 s; stopping")
    Emergency.run()
    exit(3)
}
watchdog.resume()

out(harness.header())
let selected = Harness.tests.filter { options.only?.contains($0.id) ?? true }
var results: [TestResult] = []
for test in selected {
    let result = harness.run(test)
    results.append(result)
    out(result.line)
}
harness.cleanup()
watchdog.cancel()

let duration = msFrom(harness.runStartNs, to: nowNs())
var counts: [Status: Int] = [:]
results.forEach { counts[$0.outcome.status, default: 0] += 1 }
let n = { (s: Status) in counts[s] ?? 0 }
out("\(results.count) tests: \(n(.pass)) passed, \(n(.fail)) failed, \(n(.skip)) skipped, \(n(.inconclusive)) inconclusive (\(String(format: "%.1f", duration / 1000)) s)")

if let path = options.jsonPath {
    let object: [String: Any] = [
        "startedAt": ISO8601DateFormatter().string(from: harness.runStartDate),
        "durationMs": round1(duration),
        "statePath": options.statePath,
        "logPath": options.logPath,
        "windowStrip": orNull(harness.reader.latest.map { ["pid": Int($0.pid), "engine": orNull($0.engine)] as [String: Any] }),
        "options": ["only": orNull(options.only), "noMouse": options.noMouse] as [String: Any],
        "summary": ["pass": n(.pass), "fail": n(.fail), "skip": n(.skip), "inconclusive": n(.inconclusive)],
        "results": results.map { r -> [String: Any] in
            ["id": r.test.id, "name": r.test.name, "status": r.outcome.status.rawValue,
             "timing": orNull(r.outcome.timing), "detail": r.outcome.detail, "line": r.line,
             "durationMs": round1(r.durationMs), "metrics": r.outcome.metrics, "log": r.log]
        },
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    } catch {
        warn("could not write \(path): \(error)")
    }
}
exit(n(.fail) > 0 ? 1 : 0)
