// WindowStrip v1 engine (polling, AX on the main thread) with logging, the
// state file and the notch fix added. Kept only as the baseline the test
// harness measures the new engine against: ./build.sh --legacy

import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

let stripLevel = NSWindow.Level(rawValue: 26)
let tooltipLevel = NSWindow.Level(rawValue: 28)
let iconSize: CGFloat = 20
let slotWidth: CGFloat = 30
let groupGap: CGFloat = 6
let leadingInset: CGFloat = 14

struct WinInfo: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let appName: String
    let display: CGDirectDisplayID
}

func axWindows(_ pid: pid_t) -> [(CGWindowID, AXUIElement)]? {
    let start = uptimeNs()
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(app, 0.3)
    var value: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
    let took = msSince(start)
    if took > 20 || err != .success { Log.debug("ax", "windows pid=\(pid) err=\(err.rawValue) \(ms(took))") }
    guard err == .success, let windows = value as? [AXUIElement] else { return nil }
    return windows.compactMap { element in
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(element, &id) == .success ? (id, element) : nil
    }
}

func axString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}

func promptForAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
}

final class WindowSource {
    private var isDocumentWindow: [CGWindowID: Bool] = [:]
    private var checkedAt: [CGWindowID: Date] = [:]
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    func visibleWindows(_ all: [CGWin]) -> [WinInfo] {
        var displays: [(CGDirectDisplayID, CGRect)] = []
        for screen in NSScreen.screens {
            if let id = displayID(of: screen) { displays.append((id, CGDisplayBounds(id))) }
        }
        let trusted = AXIsProcessTrusted()
        var result: [WinInfo] = []
        var seen = Set<CGWindowID>()
        for w in all {
            guard w.layer == 0, w.pid != ownPid, w.alpha > 0,
                  w.frame.width >= 80, w.frame.height >= 60,
                  let app = NSRunningApplication(processIdentifier: w.pid),
                  app.activationPolicy == .regular else { continue }
            seen.insert(w.id)
            if trusted && !documentWindow(w.id, pid: w.pid) { continue }
            let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
            let display = displays.first(where: { $0.1.contains(center) })?.0 ?? CGMainDisplayID()
            let name = app.localizedName ?? app.bundleIdentifier ?? "App"
            result.append(WinInfo(id: w.id, pid: w.pid, appName: name, display: display))
        }
        isDocumentWindow = isDocumentWindow.filter { seen.contains($0.key) }
        checkedAt = checkedAt.filter { seen.contains($0.key) }
        return result
    }

    private func documentWindow(_ id: CGWindowID, pid: pid_t) -> Bool {
        if isDocumentWindow[id] == true { return true }
        if isDocumentWindow[id] == false, let t = checkedAt[id], Date().timeIntervalSince(t) < 5 { return false }
        guard let windows = axWindows(pid) else { return true }
        let now = Date()
        for (wid, element) in windows {
            let subrole = axString(element, kAXSubroleAttribute)
            isDocumentWindow[wid] = subrole == (kAXStandardWindowSubrole as String)
                || subrole == (kAXDialogSubrole as String)
            checkedAt[wid] = now
        }
        if isDocumentWindow[id] == nil {
            isDocumentWindow[id] = false
            checkedAt[id] = now
        }
        return isDocumentWindow[id] ?? true
    }
}

final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WindowButton: NSView {
    let info: WinInfo
    private let icon: NSImage
    weak var controller: StripController?
    var isFront = false { didSet { if isFront != oldValue { needsDisplay = true } } }
    private var hovering = false

    init(info: WinInfo, icon: NSImage, frame: NSRect) {
        self.info = info
        self.icon = icon
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) {
        hovering = true; needsDisplay = true
        controller?.showTooltip(for: self)
    }
    override func mouseExited(with event: NSEvent) {
        hovering = false; needsDisplay = true
        controller?.hideTooltip()
    }
    override func mouseDown(with event: NSEvent) { Log.debug("click", "down on #\(info.id) \(info.appName)") }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { controller?.raise(info) }
    }
    override func draw(_ dirtyRect: NSRect) {
        if isFront || hovering {
            NSColor.white.withAlphaComponent(isFront ? 0.24 : 0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 3), xRadius: 6, yRadius: 6).fill()
        }
        let side = min(iconSize, bounds.width - 4)
        icon.draw(in: NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side))
    }
}

final class Tooltip {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private(set) var windowId: CGWindowID?
    private(set) var text = ""
    var isVisible: Bool { panel.isVisible }

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = tooltipLevel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(white: 0.13, alpha: 0.97).cgColor
        box.layer?.cornerRadius = 7
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        panel.contentView = box
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        box.addSubview(label)
    }

    func show(_ text: String, for id: CGWindowID, below anchor: NSRect) {
        self.text = text
        windowId = id
        label.stringValue = text
        label.sizeToFit()
        let textWidth = min(label.frame.width, 460)
        let width = textWidth + 20
        let height: CGFloat = 24
        label.frame = NSRect(x: 10, y: (height - label.frame.height) / 2, width: textWidth, height: label.frame.height)
        var x = anchor.minX
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) }) {
            x = max(screen.frame.minX + 6, min(x, screen.frame.maxX - width - 6))
        }
        panel.setFrame(NSRect(x: x, y: anchor.minY - height - 6, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        windowId = nil
        panel.orderOut(nil)
    }
}

final class StripController: NSObject {
    private let source = WindowSource()
    private let tooltip = Tooltip()
    private let watchdog = StallWatchdog()
    private var panels: [CGDirectDisplayID: StripPanel] = [:]
    private var iconLimits: [CGDirectDisplayID: CGFloat] = [:]
    private var neighbours: [Neighbour] = []
    private var icons: [pid_t: NSImage] = [:]
    private var lastSignature = ""
    private var timer: Timer?
    private var ticks = 0
    private var refreshTimes = Ring(capacity: 200)
    private var lastRaise: [String: Any] = [:]
    private let ownPid = ProcessInfo.processInfo.processIdentifier

    func start() {
        Log.info("start", "WindowStrip legacy engine pid=\(ownPid) trusted=\(AXIsProcessTrusted()) verbose=\(Log.verbose)")
        watchdog.start()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspace.addObserver(self, selector: #selector(somethingChanged(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(refreshRequested), name: NSNotification.Name("dev.windowstrip.refresh"), object: nil)
        timer = Timer.scheduledTimer(timeInterval: 1.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        buildPanels()
        refresh(reason: "start", force: true)
        if !AXIsProcessTrusted() { promptForAccessibility() }
    }

    @objc private func somethingChanged(_ note: Notification) {
        let name = note.name.rawValue.replacingOccurrences(of: "NSWorkspace", with: "").replacingOccurrences(of: "Notification", with: "")
        Log.debug("event", name)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.refresh(reason: "ws:\(name)") }
    }
    @objc private func refreshRequested() { refresh(reason: "requested", force: true) }
    @objc private func tick() {
        ticks += 1
        refresh(reason: "poll", force: ticks % 2 == 0)
    }
    @objc private func screensChanged() {
        Log.info("screens", NSScreen.screens.map { "\($0.localizedName) \($0.frame) top=\($0.safeAreaInsets.top)" }.joined(separator: "; "))
        buildPanels()
        refresh(reason: "screens", force: true)
    }

    private func buildPanels() {
        tooltip.hide()
        panels.values.forEach { $0.orderOut(nil) }
        panels = [:]
        for screen in NSScreen.screens {
            let height = screen.safeAreaInsets.top
            guard height > 0, let id = displayID(of: screen) else { continue }
            let width = screen.auxiliaryTopLeftArea?.width ?? (screen.frame.width / 2 - 90)
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: width, height: height)
            let panel = StripPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = stripLevel
            panel.backgroundColor = .black
            panel.isOpaque = true
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.isExcludedFromWindowsMenu = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
            panels[id] = panel
            Log.info("panel", "display \(id) frame \(cgRect(fromAppKit: frame)) level \(stripLevel.rawValue) window #\(panel.windowNumber)")
        }
    }

    private func refresh(reason: String, force: Bool = false) {
        let start = uptimeNs()
        Activity.run("refresh(\(reason))") {
            let all = onScreenWindows()
            let windows = source.visibleWindows(all)
            updateNeighbours(all)
            let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let frontId = windows.first(where: { $0.pid == frontPid })?.id
            let sorted = windows.sorted { a, b in
                let order = a.appName.localizedCaseInsensitiveCompare(b.appName)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
            let signature = sorted.map { "\($0.id)@\($0.display)" }.joined(separator: ",") + "|\(frontId ?? 0)|\(iconLimits)"
            let changed = signature != lastSignature
            if changed || force {
                lastSignature = signature
                for (display, panel) in panels {
                    render(sorted.filter { $0.display == display }, frontId: frontId, in: panel, display: display)
                }
            }
            let took = msSince(start)
            refreshTimes.add(took)
            if changed {
                Log.debug("render", "reason=\(reason) \(ms(took)) front=#\(frontId ?? 0) [\(sorted.map { "#\($0.id) \($0.appName)" }.joined(separator: ", "))]")
            }
            if changed || force { writeState() }
        }
    }

    private func updateNeighbours(_ all: [CGWin]) {
        var found: [Neighbour] = []
        for (display, panel) in panels {
            let strip = cgRect(fromAppKit: panel.frame)
            let near = Notch.neighbours(in: all, strip: strip, level: panel.level.rawValue, ownPid: ownPid)
            Notch.stayBelow(near, panel: panel, windows: all)
            iconLimits[display] = Notch.iconLimit(strip: strip, neighbours: near)
            found += near
        }
        let before = Notch.describe(neighbours), after = Notch.describe(found)
        if before != after { Log.info("notch", "neighbours: \(after.isEmpty ? "none" : after) limit=\(iconLimits)") }
        neighbours = found
    }

    private func render(_ windows: [WinInfo], frontId: CGWindowID?, in panel: StripPanel, display: CGDirectDisplayID) {
        guard let content = panel.contentView else { return }
        let existing = content.subviews.compactMap { $0 as? WindowButton }
        if existing.map(\.info.id) == windows.map(\.id), existing.last.map({ $0.frame.maxX <= (iconLimits[display] ?? .greatestFiniteMagnitude) }) ?? true {
            existing.forEach { $0.isFront = $0.info.id == frontId }
            return
        }
        tooltip.hide()
        content.subviews.forEach { $0.removeFromSuperview() }
        let limit = iconLimits[display] ?? content.bounds.width
        let groups = Set(windows.map(\.pid)).count
        let needed = leadingInset + CGFloat(windows.count) * slotWidth + CGFloat(max(0, groups - 1)) * groupGap
        let slot = needed <= limit ? slotWidth
            : max(18, (limit - leadingInset - CGFloat(max(0, groups - 1)) * groupGap) / CGFloat(max(1, windows.count)))
        var x = leadingInset
        var previousPid: pid_t?
        for w in windows {
            if let p = previousPid, p != w.pid { x += groupGap }
            let button = WindowButton(info: w, icon: icon(for: w.pid), frame: NSRect(x: x, y: 0, width: slot, height: content.bounds.height))
            button.isFront = w.id == frontId
            button.controller = self
            content.addSubview(button)
            x += slot
            previousPid = w.pid
        }
    }

    private func icon(for pid: pid_t) -> NSImage {
        if let cached = icons[pid] { return cached }
        let image = NSRunningApplication(processIdentifier: pid)?.icon ?? NSImage(named: NSImage.applicationIconName)!
        icons[pid] = image
        return image
    }

    func showTooltip(for button: WindowButton) {
        guard let window = button.window else { return }
        let start = uptimeNs()
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let text = Activity.run("title") { title(for: button.info) }
        tooltip.show(text, for: button.info.id, below: anchor)
        Log.debug("hover", "enter #\(button.info.id) \(button.info.appName) tooltip in \(ms(msSince(start)))")
        writeState()
    }

    func hideTooltip() {
        tooltip.hide()
        writeState()
    }

    private func title(for w: WinInfo) -> String {
        let title = axWindows(w.pid)?.first(where: { $0.0 == w.id }).flatMap { axString($0.1, kAXTitleAttribute) } ?? ""
        return title.isEmpty || title == w.appName ? w.appName : "\(w.appName) · \(title)"
    }

    func raise(_ w: WinInfo) {
        let start = uptimeNs()
        tooltip.hide()
        var steps: [String] = []
        if AXIsProcessTrusted() {
            if let target = axWindows(w.pid)?.first(where: { $0.0 == w.id })?.1 {
                steps.append("main=\(AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue).rawValue)")
                steps.append("raise=\(AXUIElementPerformAction(target, kAXRaiseAction as CFString).rawValue)")
            } else {
                steps.append("window-not-found")
            }
            steps.append("frontmost=\(AXUIElementSetAttributeValue(AXUIElementCreateApplication(w.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue).rawValue)")
        } else {
            promptForAccessibility()
        }
        steps.append("activate=\(NSRunningApplication(processIdentifier: w.pid)?.activate() ?? false)")
        Log.info("raise", "#\(w.id) \(w.appName) \(steps.joined(separator: " ")) in \(ms(msSince(start)))")
        lastRaise = ["windowId": Int(w.id), "requestedAtUptimeNs": start, "result": "pending", "ms": 0]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.refresh(reason: "raise") }
        for delay in [0.15, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let front = onScreenWindows().first(where: { $0.layer == 0 && $0.alpha > 0 && $0.frame.width >= 80 && $0.frame.height >= 60 })
                let ok = front?.id == w.id && NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid
                Log.info("raise", "check +\(Int(delay * 1000))ms #\(w.id): \(ok ? "front" : "NOT front (front is #\(front?.id ?? 0) \(front?.owner ?? "?"))")")
                if ok || delay >= 0.5 {
                    self.lastRaise["result"] = ok ? "ok" : "fail"
                    self.lastRaise["ms"] = msSince(start)
                    self.writeState()
                }
            }
        }
    }

    private func writeState() {
        let flip = flipHeight()
        var panelList: [[String: Any]] = []
        for (display, panel) in panels {
            let buttons = (panel.contentView?.subviews ?? []).compactMap { $0 as? WindowButton }.map { b -> [String: Any] in
                let screenRect = panel.convertToScreen(b.convert(b.bounds, to: nil))
                return ["windowId": Int(b.info.id), "pid": Int(b.info.pid), "app": b.info.appName, "front": b.isFront,
                        "frame": json(CGRect(x: screenRect.minX, y: flip - screenRect.maxY, width: screenRect.width, height: screenRect.height))]
            }
            panelList.append(["display": Int(display), "windowNumber": panel.windowNumber, "level": panel.level.rawValue,
                              "frame": json(cgRect(fromAppKit: panel.frame)), "iconAreaMaxX": Double(iconLimits[display] ?? panel.frame.width),
                              "buttons": buttons])
        }
        var tip: [String: Any] = ["visible": tooltip.isVisible, "chars": tooltip.text.count]
        if let id = tooltip.windowId, tooltip.isVisible {
            tip["windowId"] = Int(id)
            let pid = panels.values.flatMap { ($0.contentView?.subviews ?? []).compactMap { $0 as? WindowButton } }.first(where: { $0.info.id == id })?.info.pid
            if let pid, NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == testAppBundleID { tip["text"] = tooltip.text }
        }
        StateFile.write([
            "version": 2, "engine": "legacy", "pid": Int(ownPid), "writtenAtUptimeNs": uptimeNs(), "trusted": AXIsProcessTrusted(),
            "panels": panelList, "tooltip": tip,
            "neighbours": neighbours.map { ["windowId": Int($0.win.id), "owner": $0.win.owner, "pid": Int($0.win.pid), "layer": $0.win.layer, "frame": json($0.win.frame), "closed": $0.closed] as [String: Any] },
            "lastRaise": lastRaise, "recentRefreshMs": refreshTimes.values,
            "stalls": watchdog.recent.map { ["atUptimeNs": $0.at, "ms": $0.ms] as [String: Any] },
        ])
    }
}

Log.start()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StripController()
controller.start()
app.run()
