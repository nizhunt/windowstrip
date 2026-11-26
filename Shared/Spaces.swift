// What the window server says about Spaces. Compiled into both the app and
// the wslist helper (build.sh), so the helper's replies and the app's
// in-process fallback agree.

import CoreGraphics
import Foundation

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?

struct SpaceState {
    /// Displays whose current Space belongs to a full-screen app (Space type
    /// 4), by UUID. "Main" stands for every display when they share Spaces.
    var fullScreen: Set<String> = []
    /// Where each display's current Space sits in Mission Control's order,
    /// by the same names: which way a desktop switch went.
    var positions: [String: Int] = [:]
    /// The Space each display is showing.
    var current: Set<UInt64> = []

    /// About 0.3 ms.
    static func now() -> SpaceState {
        var s = SpaceState()
        let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()).takeRetainedValue() as? [[String: Any]] ?? []
        for d in displays {
            guard let name = d["Display Identifier"] as? String,
                  let current = d["Current Space"] as? [String: Any], let id = spaceID(current) else { continue }
            s.current.insert(id)
            if (current["type"] as? NSNumber)?.intValue == 4 { s.fullScreen.insert(name) }
            if let i = (d["Spaces"] as? [[String: Any]] ?? []).firstIndex(where: { spaceID($0) == id }) {
                s.positions[name] = i
            }
        }
        return s
    }

    /// True when the window server puts this window only on Spaces no display
    /// is showing. During a desktop switch the on-screen list has both
    /// desktops' windows; this tells them apart. Unknown counts as showing.
    func elsewhere(_ window: CGWindowID) -> Bool {
        guard !current.isEmpty,
              let spaces = CGSCopySpacesForWindows(CGSMainConnectionID(), 7, [NSNumber(value: window)] as CFArray)?
                .takeRetainedValue() as? [NSNumber], !spaces.isEmpty else { return false }
        return current.isDisjoint(with: spaces.map(\.uint64Value))
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
