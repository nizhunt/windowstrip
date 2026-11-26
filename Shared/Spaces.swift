// What the window server says about Spaces. Compiled into both the app and
// the wslist helper (build.sh), so the helper's replies and the app's
// in-process fallback agree.

import CoreGraphics
import Foundation

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?
@_silgen_name("CGSClearWindowTags") func CGSClearWindowTags(_ cid: Int32, _ wid: CGWindowID, _ tags: UnsafeMutablePointer<UInt32>, _ bits: Int32) -> Int32

/// Clears a window's "every Space" flag (window-server tag bit 11, which
/// AppKit sets for `.canJoinAllSpaces`) behind AppKit's back. It leaves the
/// window on the current desktop only, a stand-in for what a full-screen app
/// once did to the strip. Only works on this process's own windows; only the
/// tests' hook uses it.
func dropOwnWindowSticky(_ window: CGWindowID) {
    var tags: [UInt32] = [0x800, 0]
    _ = CGSClearWindowTags(CGSMainConnectionID(), window, &tags, 64)
}

struct SpaceState {
    /// Displays whose current Space belongs to a full-screen app (Space type
    /// 4), by UUID. "Main" stands for every display when they share Spaces.
    var fullScreen: Set<String> = []
    /// Where each display's current Space sits in Mission Control's order,
    /// by the same names: which way a desktop switch went.
    var positions: [String: Int] = [:]
    /// The Space each display is showing.
    var current: Set<UInt64> = []
    /// Each display's desktops (Space type 0), by the same names.
    var desktops: [String: Set<UInt64>] = [:]

    /// About 0.3 ms.
    static func now() -> SpaceState {
        var s = SpaceState()
        let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()).takeRetainedValue() as? [[String: Any]] ?? []
        for d in displays {
            guard let name = d["Display Identifier"] as? String else { continue }
            let spaces = d["Spaces"] as? [[String: Any]] ?? []
            s.desktops[name] = Set(spaces.filter { ($0["type"] as? NSNumber)?.intValue == 0 }.compactMap { spaceID($0) })
            guard let current = d["Current Space"] as? [String: Any], let id = spaceID(current) else { continue }
            s.current.insert(id)
            if (current["type"] as? NSNumber)?.intValue == 4 { s.fullScreen.insert(name) }
            if let i = spaces.firstIndex(where: { spaceID($0) == id }) { s.positions[name] = i }
        }
        return s
    }

    /// The Spaces the window server puts a window on; empty when unknown.
    static func spaces(of window: CGWindowID) -> Set<UInt64> {
        let list = CGSCopySpacesForWindows(CGSMainConnectionID(), 7, [NSNumber(value: window)] as CFArray)?
            .takeRetainedValue() as? [NSNumber] ?? []
        return Set(list.map(\.uint64Value))
    }

    /// True when the window server puts this window only on Spaces no display
    /// is showing. During a desktop switch the on-screen list has both
    /// desktops' windows; this tells them apart. Unknown counts as showing.
    func elsewhere(_ window: CGWindowID) -> Bool {
        guard !current.isEmpty else { return false }
        let spaces = SpaceState.spaces(of: window)
        return !spaces.isEmpty && current.isDisjoint(with: spaces)
    }

    private static func spaceID(_ space: [String: Any]) -> UInt64? {
        (space["id64"] as? NSNumber)?.uint64Value ?? (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }

    // The helper's reply fields: "uuid,uuid" and "uuid=0,uuid=2".
    var fullScreenField: String { fullScreen.sorted().joined(separator: ",") }
    var positionsField: String {
        positions.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
    }
    static func parse(fullScreen: Substring, positions: Substring) -> SpaceState {
        var s = SpaceState()
        s.fullScreen = Set(fullScreen.split(separator: ",").map(String.init))
        for item in positions.split(separator: ",") {
            let kv = item.split(separator: "=")
            if kv.count == 2, let i = Int(kv[1]) { s.positions[String(kv[0])] = i }
        }
        return s
    }
}
