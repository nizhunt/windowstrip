// WSTestApp: a scriptable app for the WindowStrip test harness.
//
// Reads one command per line on stdin, runs it on the main thread and answers
// each with one JSON line on stdout. Coordinates are global CG points (origin
// at the top-left of the primary screen). It quits when stdin closes, so it
// never outlives the runner that started it.
//
//   open <tag> standard|panel|borderless <x> <y> <w> <h> [title…]
//   close|minimize|deminimize|focus <tag>
//   title <tag> <text…>
//   hide | unhide | status | quit
//
// Every reply has "ok" and "cmd"; failures add "error". Commands that change
// something add "atUptimeNs" (DispatchTime uptime, the same clock as
// WindowStrip's state.json).

import AppKit

@inline(__always) func uptimeNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

struct CommandError: Error { let message: String }

/// A borderless window that refuses key status, like overlay and helper windows.
final class BorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class Controller: NSObject, NSApplicationDelegate {
    private var windows: [String: NSWindow] = [:]
    private var kinds: [String: String] = [:]
    private var order: [String] = []        // tags, oldest first
    private var activeSinceNs: UInt64 = 0
    private var keySinceNs: UInt64 = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.activeSinceNs = uptimeNs()
        }
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.keySinceNs = uptimeNs()
        }
        let reader = Thread {
            while let line = readLine(strippingNewline: true) {
                DispatchQueue.main.async { self.handle(line) }
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }   // stdin closed: the runner is gone
        }
        reader.name = "stdin"
        reader.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Protocol

    private func handle(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let cmd = String(parts[0])
        let rest = parts.count > 1 ? String(parts[1]) : ""
        do {
            var reply = try run(cmd, rest)
            reply["ok"] = true
            reply["cmd"] = cmd
            send(reply)
            if cmd == "quit" { DispatchQueue.main.async { NSApp.terminate(nil) } }
        } catch let error as CommandError {
            send(["ok": false, "cmd": cmd, "error": error.message])
        } catch {
            send(["ok": false, "cmd": cmd, "error": "\(error)"])
        }
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else {
            FileHandle.standardError.write("could not encode reply\n".data(using: .utf8)!)
            return
        }
        data.append(0x0A)
        // write(2) is unbuffered, so each reply reaches the pipe at once.
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(1, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 { if errno == EINTR { continue }; return }
                offset += n
            }
        }
    }

    private func run(_ cmd: String, _ rest: String) throws -> [String: Any] {
        switch cmd {
        case "open": return try open(rest)
        case "close":
            let (tag, window) = try lookup(rest)
            window.close()
            let at = uptimeNs()
            windows[tag] = nil
            kinds[tag] = nil
            order.removeAll { $0 == tag }
            return ["tag": tag, "atUptimeNs": at]
        case "minimize":
            let (tag, window) = try lookup(rest)
            window.miniaturize(nil)
            return ["tag": tag, "atUptimeNs": uptimeNs()]
        case "deminimize":
            let (tag, window) = try lookup(rest)
            window.deminiaturize(nil)
            return ["tag": tag, "atUptimeNs": uptimeNs()]
        case "focus":
            let (tag, window) = try lookup(rest)
            window.makeKeyAndOrderFront(nil)
            let at = uptimeNs()
            activate()
            return ["tag": tag, "atUptimeNs": at]
        case "title":
            let parts = rest.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { throw CommandError(message: "usage: title <tag> <text…>") }
            let (tag, window) = try lookup(String(parts[0]))
            window.title = String(parts[1])
            return ["tag": tag, "title": window.title, "atUptimeNs": uptimeNs()]
        case "hide":
            NSApp.hide(nil)
            return ["atUptimeNs": uptimeNs()]
        case "unhide":
            NSApp.unhide(nil)
            return ["atUptimeNs": uptimeNs()]
        case "hang":
            // Replies first, then blocks the main thread: the app stops
            // answering AX and events, as a beach-balling app does.
            guard let ms = Double(rest.trimmingCharacters(in: .whitespaces)), ms > 0, ms <= 20_000 else {
                throw CommandError(message: "usage: hang <ms> (at most 20000)")
            }
            DispatchQueue.main.async { usleep(useconds_t(ms * 1000)) }
            return ["ms": ms, "atUptimeNs": uptimeNs()]
        case "fullscreen":
            // Toggles full screen; the switch to or from the window's own Space
            // finishes about a second later.
            let (tag, window) = try lookup(rest)
            window.collectionBehavior.insert(.fullScreenPrimary)
            window.toggleFullScreen(nil)
            return ["tag": tag, "atUptimeNs": uptimeNs()]
        case "status": return status()
        case "quit": return ["atUptimeNs": uptimeNs()]
        default: throw CommandError(message: "unknown command '\(cmd)'")
        }
    }

    private func lookup(_ rest: String) throws -> (String, NSWindow) {
        let tag = rest.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty else { throw CommandError(message: "missing tag") }
        guard let window = windows[tag] else { throw CommandError(message: "no window '\(tag)'") }
        return (tag, window)
    }

    // open <tag> <kind> <x> <y> <w> <h> [title…]
    private func open(_ rest: String) throws -> [String: Any] {
        let p = rest.split(separator: " ", maxSplits: 6, omittingEmptySubsequences: true).map(String.init)
        guard p.count >= 6 else { throw CommandError(message: "usage: open <tag> <kind> <x> <y> <w> <h> [title…]") }
        let tag = p[0], kind = p[1]
        guard let x = Double(p[2]), let y = Double(p[3]), let w = Double(p[4]), let h = Double(p[5]), w > 0, h > 0 else {
            throw CommandError(message: "bad geometry '\(p[2]) \(p[3]) \(p[4]) \(p[5])'")
        }
        guard windows[tag] == nil else { throw CommandError(message: "window '\(tag)' is already open") }
        let title = p.count > 6 ? p[6] : "WSTest \(tag)"
        let frame = appKitRect(x: x, y: y, w: w, h: h)

        let window: NSWindow
        switch kind {
        case "standard":
            window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        case "panel":
            let panel = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false     // stays on screen even if the app loses focus
            window = panel
        case "borderless":
            window = BorderlessWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.level = .normal
            window.backgroundColor = .systemTeal
        default:
            throw CommandError(message: "unknown kind '\(kind)' (standard, panel, borderless)")
        }
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.animationBehavior = .none
        window.title = title
        window.contentView = label(tag)
        window.setFrame(frame, display: false)      // the geometry is the outer frame, as CGWindowList reports it

        let at: UInt64
        if kind == "standard" {
            window.makeKeyAndOrderFront(nil)
            at = uptimeNs()
            activate()
        } else {
            window.orderFront(nil)
            at = uptimeNs()
        }
        windows[tag] = window
        kinds[tag] = kind
        order.append(tag)
        return ["tag": tag, "kind": kind, "windowNumber": window.windowNumber, "atUptimeNs": at,
                "frame": cgFrame(window.frame)]
    }

    private func status() -> [String: Any] {
        func tag(of window: NSWindow?) -> Any {
            guard let window else { return NSNull() }
            return windows.first(where: { $0.value === window })?.key ?? NSNull()
        }
        let list: [[String: Any]] = order.compactMap { tag in
            guard let w = windows[tag] else { return nil }
            return ["tag": tag, "kind": kinds[tag] ?? "?", "windowNumber": w.windowNumber, "title": w.title,
                    "visible": w.isVisible, "miniaturized": w.isMiniaturized]
        }
        return ["pid": Int(getpid()), "active": NSApp.isActive, "hidden": NSApp.isHidden,
                "keyTag": tag(of: NSApp.keyWindow), "mainTag": tag(of: NSApp.mainWindow),
                "activeSinceNs": activeSinceNs, "keySinceNs": keySinceNs,
                "windows": list, "atUptimeNs": uptimeNs()]
    }

    // MARK: Helpers

    /// macOS 14 made activation cooperative; the old call still wins more often
    /// when the app was started from a terminal. The runner falls back to AX.
    private func activate() {
        NSApp.activate()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func label(_ tag: String) -> NSView {
        let view = NSView()
        let text = NSTextField(labelWithString: tag)
        text.font = .systemFont(ofSize: 36, weight: .bold)
        text.textColor = .secondaryLabelColor
        text.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(text)
        NSLayoutConstraint.activate([text.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                     text.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
        return view
    }
}

/// CG top-left points to AppKit bottom-left points. The primary screen
/// (screens[0]) holds the origin of both systems.
func appKitRect(x: Double, y: Double, w: Double, h: Double) -> NSRect {
    let flip = NSScreen.screens.first?.frame.maxY ?? 0
    return NSRect(x: x, y: flip - y - h, width: w, height: h)
}

func cgFrame(_ r: NSRect) -> [String: Double] {
    let flip = NSScreen.screens.first?.frame.maxY ?? 0
    return ["x": r.minX, "y": flip - r.maxY, "w": r.width, "h": r.height]
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let controller = Controller()
app.delegate = controller
app.run()
