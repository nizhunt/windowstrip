// Bringing one specific window to the front.
//
// macOS has no public call that activates an app and brings forward only one
// of its windows: kAXFrontmost and NSRunningApplication.activate bring the
// app's other windows along, and an app that is never active itself (like
// this one) can't count on activate() being honoured. So, like AltTab and
// yabai, this uses the window server's own calls when they exist:
//   1. _SLPSSetFrontProcessWithOptions(psn, window, userGenerated)
//   2. a make-key event pair for that window
//   3. AXRaise on the window
// and falls back to AXRaise + kAXMain + activate() when they don't.

import AppKit
import ApplicationServices

private struct PSN { var high: UInt32 = 0; var low: UInt32 = 0 }

// PSN pointers are passed as raw pointers: a Swift struct can't appear in a C function type.
private typealias GetProcessForPIDFn = @convention(c) (pid_t, UnsafeMutableRawPointer) -> Int32
private typealias SetFrontProcessFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
private typealias PostEventRecordFn = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32

enum Raiser {
    private static let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let getProcessForPID: GetProcessForPIDFn? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "GetProcessForPID").map { unsafeBitCast($0, to: GetProcessForPIDFn.self) }
    private static let setFrontProcess: SetFrontProcessFn? =
        skyLight.flatMap { dlsym($0, "_SLPSSetFrontProcessWithOptions") }.map { unsafeBitCast($0, to: SetFrontProcessFn.self) }
    private static let postEventRecord: PostEventRecordFn? =
        skyLight.flatMap { dlsym($0, "SLPSPostEventRecordTo") }.map { unsafeBitCast($0, to: PostEventRecordFn.self) }

    static var hasWindowServerCalls: Bool { getProcessForPID != nil && setFrontProcess != nil && postEventRecord != nil }

    /// `steps` is a short description of what was done, for the log;
    /// `axTimedOut` is true when the app didn't answer an AX message. With
    /// `useAX` false (the app isn't answering) no AX message is sent.
    static func raise(window id: CGWindowID, pid: pid_t, element: AXUIElement?, useAX: Bool = true) -> (steps: String, axTimedOut: Bool) {
        var steps: [String] = []
        var timedOut = false
        func ax(_ name: String, _ err: AXError) {
            steps.append("\(name)=\(err.rawValue)")
            if err == .cannotComplete { timedOut = true }
        }
        if let getProcessForPID, let setFrontProcess, let postEventRecord {
            var psn = PSN()
            let status = withUnsafeMutableBytes(of: &psn) { getProcessForPID(pid, $0.baseAddress!) }
            if status == 0 {
                let front = withUnsafeMutableBytes(of: &psn) { setFrontProcess($0.baseAddress!, id, 0x200) }  // 0x200: user generated
                steps.append("front=\(front)")
                steps.append("key=\(makeKey(&psn, id, postEventRecord))")
                if let element, useAX {
                    ax("raise", AXUIElementPerformAction(element, kAXRaiseAction as CFString))
                } else {
                    steps.append("no-ax")
                }
                return (steps.joined(separator: " "), timedOut)
            }
            steps.append("psn-error=\(status)")
        }
        // Fallback: raise first, then activate, so the app's previous main
        // window doesn't flash in front.
        if let element, useAX {
            ax("raise", AXUIElementPerformAction(element, kAXRaiseAction as CFString))
            if !timedOut { ax("main", AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)) }
        } else {
            steps.append("no-ax")
        }
        DispatchQueue.main.async { _ = NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
        steps.append("activate=requested")
        return ("fallback " + steps.joined(separator: " "), timedOut)
    }

    /// The window server's make-key event pair (the layout yabai, Hammerspoon and AltTab use).
    private static func makeKey(_ psn: inout PSN, _ id: CGWindowID, _ post: PostEventRecordFn) -> String {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        for i in 0..<4 { bytes[0x3c + i] = UInt8(truncatingIfNeeded: id >> (8 * UInt32(i))) }  // little-endian
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        let first = withUnsafeMutableBytes(of: &psn) { p in bytes.withUnsafeMutableBytes { post(p.baseAddress!, $0.baseAddress!) } }
        bytes[0x08] = 0x02
        let second = withUnsafeMutableBytes(of: &psn) { p in bytes.withUnsafeMutableBytes { post(p.baseAddress!, $0.baseAddress!) } }
        return "\(first)/\(second)"
    }
}
