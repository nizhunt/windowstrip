// spaces: reads the current desktop and switches desktops through Mission
// Control's own desktop buttons, so it works whether or not the Ctrl-arrow
// shortcuts are turned on. Used by the WindowStrip tests.
//
//   spaces current      prints "<index> of <count> (space id <id>)" for the display with the active Space
//   spaces go <index>   opens Mission Control, presses desktop <index>'s button, waits for the switch;
//                       prints "pressed <uptimeNs> switched <uptimeNs> closed <uptimeNs>"
//   spaces close        closes Mission Control if it is open, staying on the current desktop
//   spaces strips       prints how many desktop buttons Mission Control shows (no titles)
//
// Exit status 0 on success; 1 for a bad argument or a desktop that doesn't
// exist; 2 when there is no Mission Control app or a press fails; 3 when the
// switch didn't happen within 4 s; 4 when Mission Control's desktop buttons
// can't be read or told apart (no Accessibility permission, Mission Control
// didn't open, two displays without English names, or a macOS that draws
// them differently), so the tests can skip.

import AppKit
import ApplicationServices

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSGetActiveSpace") func CGSGetActiveSpace(_ cid: Int32) -> UInt64
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>

@inline(__always) func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func fail(_ code: Int32, _ text: String) -> Never { FileHandle.standardError.write((text + "\n").data(using: .utf8)!); exit(code) }

/// The display that holds the active Space: its desktops (not full-screen
/// apps) and all its Spaces, both as ids in Mission Control order.
struct Desktops {
    var ids: [UInt64] = []
    var all: [UInt64] = []
    var active: UInt64 = 0
}

func desktops() -> Desktops {
    var result = Desktops(active: CGSGetActiveSpace(CGSMainConnectionID()))
    let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()).takeRetainedValue() as? [[String: Any]] ?? []
    func id(_ s: [String: Any]) -> UInt64? {
        (s["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? (s["id64"] as? NSNumber)?.uint64Value
    }
    for d in displays {
        let spaces = d["Spaces"] as? [[String: Any]] ?? []
        let ids = spaces.filter { ($0["type"] as? NSNumber)?.intValue == 0 }.compactMap(id)   // desktops only
        if ids.contains(result.active) {
            result.ids = ids
            result.all = spaces.compactMap(id)
            return result
        }
    }
    return result
}

func axValue(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func children(_ e: AXUIElement) -> [AXUIElement] { axValue(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func identifier(_ e: AXUIElement) -> String? { axValue(e, "AXIdentifier") as? String }

typealias Strip = [(title: String?, button: AXUIElement)]

/// Mission Control's desktop strips while it is open, one per display with
/// its own Spaces: each strip's buttons in order, with their titles.
/// WindowManager draws them on macOS 27; earlier versions drew them in the Dock.
func spaceStrips() -> [Strip] {
    for bundle in ["com.apple.WindowManager", "com.apple.dock"] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { continue }
        var strips: [Strip] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            if depth > 6 { return }
            if identifier(e) == "mc.spaces.list" {
                strips.append(children(e).map { ((axValue($0, kAXTitleAttribute) ?? axValue($0, kAXDescriptionAttribute)) as? String, $0) })
                return
            }
            for c in children(e) { walk(c, depth + 1) }
        }
        walk(AXUIElementCreateApplication(app.processIdentifier), 0)
        if !strips.isEmpty { return strips }
    }
    return []
}

/// Desktop `index`'s button: by its English name "Desktop <index>" when only
/// one strip has it, else by position, which needs a single strip with one
/// button per Space.
func button(for index: Int, in d: Desktops) -> AXUIElement? {
    let strips = spaceStrips()
    let named = strips.compactMap { $0.first(where: { $0.title == "Desktop \(index)" }) }
    if named.count == 1 { return named[0].button }
    guard strips.count == 1, strips[0].count == d.all.count, d.ids.indices.contains(index - 1),
          let position = d.all.firstIndex(of: d.ids[index - 1]) else { return nil }
    return strips[0][position].button
}

func missionControlOpen() -> Bool { !spaceStrips().isEmpty }

func waitFor(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let end = now() + UInt64(seconds * 1e9)
    while now() < end { if condition() { return true }; usleep(3000) }
    return condition()
}

/// Escape closes Mission Control and stays on the current desktop. `force`
/// sends it even when the buttons can't be seen, for a Mission Control this
/// tool opened.
func closeMissionControl(force: Bool = false) {
    guard force || missionControlOpen() else { return }
    for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap) }
    _ = waitFor(2) { !missionControlOpen() }
}

func press(_ index: Int, opening: Bool, in d: Desktops) -> UInt64 {
    if opening {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.exposelauncher") else { fail(2, "no Mission Control app") }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in sem.signal() }
        _ = sem.wait(timeout: .now() + 3)
    }
    var target: AXUIElement?
    guard waitFor(3, { target = button(for: index, in: d); return target != nil }) else {
        let counts = spaceStrips().map(\.count)
        closeMissionControl(force: opening)
        fail(4, "Mission Control's button for desktop \(index) not found (\(counts.count) strips with \(counts) buttons, \(d.all.count) Spaces)")
    }
    usleep(150_000)   // let the opening animation settle so the press is taken
    let at = now()
    let err = AXUIElementPerformAction(target!, kAXPressAction as CFString)
    if err != .success { closeMissionControl(); fail(2, "pressing desktop \(index)'s button failed (\(err.rawValue))") }
    return at
}

let args = Array(CommandLine.arguments.dropFirst())
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 1.0)
switch args.first {
case "current":
    let d = desktops()
    let index = (d.ids.firstIndex(of: d.active) ?? -1) + 1
    print("\(index) of \(d.ids.count) (space id \(d.active))")
case "go":
    guard args.count > 1, let index = Int(args[1]) else { fail(1, "usage: spaces go <index>") }
    guard AXIsProcessTrusted() else { fail(4, "no Accessibility permission, so Mission Control's buttons can't be read") }
    let d = desktops()
    guard index >= 1, index <= d.ids.count else { fail(1, "desktop \(index) does not exist (\(d.ids.count) desktops)") }
    let target = d.ids[index - 1]
    if d.active == target, !missionControlOpen() { print("pressed 0 switched 0 closed 0 (already there)"); exit(0) }
    let pressed = press(index, opening: !missionControlOpen(), in: d)
    var switched: UInt64 = 0
    _ = waitFor(4) { if CGSGetActiveSpace(CGSMainConnectionID()) == target { switched = now(); return true }; return false }
    let closed = waitFor(4) { !missionControlOpen() } ? now() : 0
    print("pressed \(pressed) switched \(switched) closed \(closed)")
    if switched == 0 { closeMissionControl(); exit(3) }
case "close":
    if missionControlOpen() {
        let d = desktops()
        if let b = button(for: (d.ids.firstIndex(of: d.active) ?? 0) + 1, in: d) {
            _ = AXUIElementPerformAction(b, kAXPressAction as CFString)
            _ = waitFor(3) { !missionControlOpen() }
        }
        closeMissionControl()
    }
    print(missionControlOpen() ? "still open" : "closed")
case "strips":
    let d = desktops()
    let strips = spaceStrips()
    let titled = strips.joined().filter { $0.title?.hasPrefix("Desktop ") == true }.count
    print("\(strips.count) strips with \(strips.map(\.count)) buttons, \(titled) titled \"Desktop N\"; \(d.ids.count) desktops and \(d.all.count) Spaces on the active display")
default:
    fail(1, "usage: spaces current | go <index> | close | strips")
}
