// Geometry helpers, the window-list snapshot, the state file for tests, and
// notch neighbours (other apps' windows around the notch, such as Vorssaint's
// Dynamic Island).

import AppKit

func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

/// AppKit puts the origin at the bottom-left of the primary screen, CG at its
/// top-left. This height flips between the two.
func flipHeight() -> CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
func cgRect(fromAppKit r: NSRect) -> CGRect {
    CGRect(x: r.minX, y: flipHeight() - r.maxY, width: r.width, height: r.height)
}
func appKitRect(fromCG r: CGRect) -> NSRect {
    NSRect(x: r.minX, y: flipHeight() - r.maxY, width: r.width, height: r.height)
}

/// One window from CGWindowListCopyWindowInfo.
struct CGWin {
    let id: CGWindowID
    let pid: pid_t
    let owner: String
    let layer: Int
    let alpha: Double
    let frame: CGRect   // CG coordinates
}

/// Every on-screen window of every layer, front to back. No permission needed.
func onScreenWindows() -> [CGWin] {
    guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return [] }
    return info.compactMap { w in
        guard let id = w[kCGWindowNumber as String] as? CGWindowID,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
        return CGWin(id: id, pid: pid,
                     owner: w[kCGWindowOwnerName as String] as? String ?? "?",
                     layer: w[kCGWindowLayer as String] as? Int ?? 0,
                     alpha: w[kCGWindowAlpha as String] as? Double ?? 1,
                     frame: frame)
    }
}

// MARK: - State file

/// ~/Library/Caches/dev.windowstrip/state.json: what the bar shows, for the
/// test harness and for debugging. Holds no window titles except the test
/// app's.
enum StateFile {
    static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Caches/dev.windowstrip/state.json")
    private static let queue = DispatchQueue(label: "dev.windowstrip.state", qos: .utility)
    private static var directoryReady = false   // owned by `queue`

    /// Readers see the old file or the new one (written beside it, then
    /// renamed over it), never half of one. Not forced to disk: it's a cache.
    static func write(_ object: [String: Any]) {
        queue.async {
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
                Log.info("state", "could not encode the state")
                return
            }
            let temp = url.path + ".new"
            var fd: Int32 = -1
            // A cache sweep can delete the folder under a running app: make it again.
            for _ in 0..<2 {
                if !directoryReady {
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    directoryReady = true
                }
                fd = open(temp, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
                if fd >= 0 || errno != ENOENT { break }
                directoryReady = false
            }
            guard fd >= 0 else { Log.info("state", "could not open the state file (errno \(errno))"); return }
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            close(fd)
            guard written == data.count, rename(temp, url.path) == 0 else {
                Log.info("state", "write failed (errno \(errno))")
                return
            }
        }
    }
}

func json(_ r: CGRect) -> [String: Any] {
    ["x": Double(r.minX), "y": Double(r.minY), "w": Double(r.width), "h": Double(r.height)]
}

let testAppBundleID = "dev.windowstrip.testapp"

// MARK: - Notch neighbours

/// Another app's window on our level or above that overlaps the strip and
/// reaches the notch, such as Vorssaint's Dynamic Island.
struct Neighbour {
    let win: CGWin
    /// A closed island is about as tall as the strip. An expanded one is taller
    /// and only floats above us for a while, so it doesn't move the icons.
    let closed: Bool
}

enum Notch {
    static func neighbours(in windows: [CGWin], strip: CGRect, level: Int, ownPid: pid_t) -> [Neighbour] {
        windows.compactMap { w in
            guard w.pid != ownPid, w.layer >= level, w.alpha > 0,
                  w.frame.intersects(strip),
                  w.frame.maxX >= strip.maxX - 1,                    // reaches the notch
                  w.frame.minX > strip.minX + strip.width * 0.4      // not a full-width overlay
            else { return nil }
            return Neighbour(win: w, closed: w.frame.height <= strip.height + 4)
        }
    }

    /// Right edge, in strip coordinates, that icons stay left of.
    static func iconLimit(strip: CGRect, neighbours: [Neighbour]) -> CGFloat {
        let edges = neighbours.filter(\.closed).map { $0.win.frame.minX - strip.minX - 8 }
        return min(strip.width, edges.min() ?? strip.width)
    }

    /// Puts `panel` under any neighbour on the same level that is currently
    /// under it, so the island draws (and gets the mouse) on top of our strip.
    static func stayBelow(_ neighbours: [Neighbour], panel: NSWindow, windows: [CGWin]) {
        let ours = CGWindowID(panel.windowNumber)
        guard let ourIndex = windows.firstIndex(where: { $0.id == ours }) else { return }
        for n in neighbours where n.win.layer == panel.level.rawValue {
            guard let theirIndex = windows.firstIndex(where: { $0.id == n.win.id }), ourIndex < theirIndex else { continue }
            panel.order(.below, relativeTo: Int(n.win.id))
            Log.info("notch", "moved the strip below \(n.win.owner) #\(n.win.id) at \(n.win.frame)")
        }
    }

    static func describe(_ neighbours: [Neighbour]) -> String {
        neighbours.map { "\($0.win.owner)#\($0.win.id) L\($0.win.layer) \($0.closed ? "closed" : "open") \(Int($0.win.frame.minX))…\(Int($0.win.frame.maxX))×\(Int($0.win.frame.height))" }
            .joined(separator: ", ")
    }
}
