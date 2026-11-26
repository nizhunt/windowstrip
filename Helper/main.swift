// wslist: fetches the window server's window list for WindowStrip, in its
// own process.
//
// Why a separate process: CGWindowListCopyWindowInfo blocks for 300-400 ms
// while a window minimises, and while it waits it holds the lock on the
// calling process's window server connection. WindowStrip's main thread needs
// that lock to commit every redraw, so even with the call on a background
// thread the bar froze for the whole animation (seen in a /usr/bin/sample:
// main thread in sls_transaction_commit_ca -> _os_unfair_lock_lock_slow).
// Here the call can block without touching WindowStrip's connection.
//
// Protocol, one line each way:
//   request:  "<id> onscreen"  or  "<id> all"
//   reply:    "<id>\t<microseconds>\t<full-screen>\t<desktops>\t<left out>\t<windows>"
// onscreen: windows separated by U+001F, each "id,pid,layer,alpha,x,y,w,h,owner"
//           (front to back; the owner name is last because it can contain commas).
//           full-screen: the UUIDs of the displays showing a full-screen app's
//           Space, separated by commas ("Main" when all displays share one set
//           of Spaces). desktops: "<display>=<n>" per display, n being where its
//           current Space sits in Mission Control's order. left out: how many
//           windows were dropped because they sit only on Spaces no display
//           shows (during a desktop switch the window server lists both
//           desktops' windows as on screen).
// all:      window ids separated by commas (every window, every Space); the
//           other fields empty.
// The helper exits when its stdin closes, so it dies with WindowStrip.
// Shared/Spaces.swift is compiled in with this file.

import CoreGraphics
import Foundation

@inline(__always) func uptimeUs() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }

func onScreen() -> (body: String, spaces: SpaceState, leftOut: Int) {
    let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    // Read after the list, so a switch that ends meanwhile decides.
    let spaces = SpaceState.now()
    var parts: [String] = []
    parts.reserveCapacity(info.count)
    var leftOut = 0
    for w in info {
        guard let id = w[kCGWindowNumber as String] as? UInt32,
              let pid = w[kCGWindowOwnerPID as String] as? Int32,
              let dict = w[kCGWindowBounds as String] as? [String: Any],
              let b = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        if layer == 0, spaces.elsewhere(id) { leftOut += 1; continue }
        let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
        let owner = (w[kCGWindowOwnerName as String] as? String ?? "?")
            .replacingOccurrences(of: "\u{1f}", with: " ").replacingOccurrences(of: "\n", with: " ")
        parts.append("\(id),\(pid),\(layer),\(alpha),\(b.minX),\(b.minY),\(b.width),\(b.height),\(owner)")
    }
    return (parts.joined(separator: "\u{1f}"), spaces, leftOut)
}

func allIDs() -> String {
    guard let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return "" }
    return info.compactMap { ($0[kCGWindowNumber as String] as? UInt32).map(String.init) }.joined(separator: ",")
}

signal(SIGPIPE, SIG_IGN)
while let line = readLine() {
    let fields = line.split(separator: " ")
    guard let id = fields.first else { continue }
    let all = fields.count > 1 && fields[1] == "all"
    let start = uptimeUs()
    let reply: String
    if all {
        let body = allIDs()
        reply = "\(id)\t\(uptimeUs() - start)\t\t\t\t\(body)\n"
    } else {
        let (body, spaces, leftOut) = onScreen()
        reply = "\(id)\t\(uptimeUs() - start)\t\(spaces.fullScreenField)\t\(spaces.positionsField)\t\(leftOut)\t\(body)\n"
    }
    guard FileHandle.standardOutput.writeData(reply) else { exit(0) }
}
exit(0)

extension FileHandle {
    /// False when the reader is gone.
    func writeData(_ text: String) -> Bool {
        do { try write(contentsOf: Data(text.utf8)); return true } catch { return false }
    }
}
