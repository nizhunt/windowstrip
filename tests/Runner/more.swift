// More end-to-end tests (T19-T28): desktop switches, a resting pointer, a
// hung app, overflow, a soak, the notch order after a restart, the window
// order a click leaves behind, a late raise from a busy app, a window going
// full screen, and a strip that drops off the other desktops.

import AppKit
import ApplicationServices

struct DesktopInfo { let index: Int; let count: Int }

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>
@_silgen_name("CGSCopySpacesForWindows") func CGSCopySpacesForWindows(_ cid: Int32, _ mask: Int32, _ windows: CFArray) -> Unmanaged<CFArray>?

/// The notched display's entry in the window server's list of Spaces (or the
/// first one, which is "Main" when displays share Spaces).
func notchDisplaySpaces() -> [String: Any]? {
    let displays = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()).takeRetainedValue() as? [[String: Any]] ?? []
    var uuid: String?
    if let screen = notchScreens().first,
       let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
       let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
        uuid = CFUUIDCreateString(nil, u) as String
    }
    return displays.first { ($0["Display Identifier"] as? String) == uuid } ?? displays.first
}

func managedSpaceID(_ space: [String: Any]?) -> UInt64? {
    ((space?["id64"] as? NSNumber) ?? (space?["ManagedSpaceID"] as? NSNumber))?.uint64Value
}

/// The current Space type on the notched display (or the first one):
/// 0 a desktop, 4 a full-screen app; -1 if unknown.
func currentSpaceType() -> Int {
    ((notchDisplaySpaces()?["Current Space"] as? [String: Any])?["type"] as? NSNumber)?.intValue ?? -1
}

/// The Space the notched display shows.
func currentSpace() -> UInt64? { managedSpaceID(notchDisplaySpaces()?["Current Space"] as? [String: Any]) }

/// The notched display's desktops (Space type 0).
func notchDesktops() -> Set<UInt64> {
    let spaces = notchDisplaySpaces()?["Spaces"] as? [[String: Any]] ?? []
    return Set(spaces.filter { ($0["type"] as? NSNumber)?.intValue == 0 }.compactMap { managedSpaceID($0) })
}

/// The Spaces the window server puts a window on (any process's window).
func spacesOf(_ window: UInt32) -> Set<UInt64> {
    let list = CGSCopySpacesForWindows(CGSMainConnectionID(), 7, [NSNumber(value: window)] as CFArray)?
        .takeRetainedValue() as? [NSNumber] ?? []
    return Set(list.map(\.uint64Value))
}

/// Turns WindowStrip's test hooks on or off (off removes the setting).
func setTestHooks(_ on: Bool) {
    CFPreferencesSetAppValue("testHooks" as CFString, on ? kCFBooleanTrue : nil, "dev.windowstrip" as CFString)
    _ = CFPreferencesAppSynchronize("dev.windowstrip" as CFString)
}

extension Harness {

    // MARK: - Helpers

    /// Runs a tool and returns its exit status and output (stdout and stderr).
    func runTool(_ path: String, _ args: [String], timeoutMs: Double = 10_000) -> (status: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let end = nowNs() + ns(timeoutMs)
        while p.isRunning && nowNs() < end { sleepMs(5) }
        if p.isRunning { p.terminate(); return (-2, "timed out") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var spacesTool: String { buildDir + "/spaces" }

    /// "2 of 3 (space id 4)" from `spaces current`.
    func desktop() -> DesktopInfo? {
        let r = runTool(spacesTool, ["current"])
        let f = r.out.split(separator: " ")
        guard r.status == 0, f.count >= 3, let i = Int(f[0]), let n = Int(f[2]) else { return nil }
        return DesktopInfo(index: i, count: n)
    }

    /// What a desktop switch through the spaces tool came to.
    enum DesktopSwitch { case done(UInt64), unsupported(String), failed }

    /// Switches desktops through Mission Control. `.done` carries when the
    /// switch happened (uptime ns, the same clock as WindowStrip's).
    /// `.unsupported` means the tool couldn't find Mission Control's desktop
    /// buttons (exit 4), so a test can skip rather than fail.
    func switchDesktop(_ index: Int) -> DesktopSwitch {
        let r = runTool(spacesTool, ["go", String(index)])
        let f = r.out.split(separator: " ")   // pressed <ns> switched <ns> closed <ns>
        guard r.status == 0, f.count >= 4, let switched = UInt64(f[3]) else {
            warn("spaces go \(index): status \(r.status): \(r.out)")
            return r.status == 4 ? .unsupported(r.out) : .failed
        }
        return .done(switched == 0 ? nowNs() : switched)
    }

    func goToDesktop(_ index: Int) -> UInt64? {
        if case .done(let at) = switchDesktop(index) { return at }
        return nil
    }

    /// The bar's buttons, with app names only (no titles).
    func barText(_ s: StripState? = nil) -> String {
        guard let s = s ?? reader.latest else { return "no state" }
        return "[" + s.buttons.map { "#\($0.windowId) \($0.app ?? "?")" }.joined(separator: ", ") + "]"
    }

    /// Buttons for windows that are not on screen (stale), and on-screen
    /// standard test windows with no button (missing).
    func mismatch(_ s: StripState) -> (stale: [UInt32], missing: [UInt32]) {
        let onScreen = cgWindows().filter { $0.layer == 0 && $0.alpha > 0 }
        let ids = Set(onScreen.map(\.id))
        let stale = s.buttons.map(\.windowId).filter { !ids.contains($0) }
        let standard = Set(wins.values.filter { !["P", "Z"].contains($0.tag) }.map(\.number))
        let missing = onScreen.filter { standard.contains($0.id) && !s.has($0.id) }.map(\.id)
        return (stale, missing)
    }

    func pctText(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "none" }
        let v = values.sorted()
        let p = { (q: Double) in v[min(v.count - 1, max(0, Int((q * Double(v.count)).rounded(.up)) - 1))] }
        return "p50 \(msText(p(0.5))) p95 \(msText(p(0.95))) max \(msText(v.last!)) (n \(v.count))"
    }

    func tags(_ ids: [UInt32]) -> String {
        ids.map { id in wins.values.first { $0.number == id }?.tag ?? "#\(id)" }.joined(separator: " > ")
    }

    /// Quits one test app and forgets it and its windows.
    func quitApp(_ name: String) {
        guard let a = apps[name] else { return }
        a.shutdown()
        apps[name] = nil
        wins = wins.filter { $0.value.app !== a }
    }

    // MARK: - T19 desktop switches

    /// T19: A is on the home desktop and D on the next one. After each switch
    /// the bar shows that desktop's windows and none from the other, within
    /// 300 ms of the switch. Four round trips through Mission Control; the
    /// test always ends on the home desktop.
    func t19() throws -> Outcome {
        guard FileManager.default.isExecutableFile(atPath: spacesTool) else { return .skip("tests/build/spaces is not built") }
        guard let here = desktop() else { return .inconclusive("could not read the current desktop") }
        guard here.count >= 2 else { return .skip("only one desktop") }
        let home = here.index, other = home < here.count ? home + 1 : home - 1
        let app = try app("app1")
        let a = try ensure("A", in: app, shown: true)
        defer {
            if let d = desktop(), d.index != home { _ = goToDesktop(home) }
        }

        var away: [Double] = [], back: [Double] = [], problems: [String] = []
        var d: Win?
        var dAppear: Double?
        let rounds = 4
        func checkSettled(_ label: String) {
            sleepMs(250)
            guard let s = reader.read() else { return }
            let m = mismatch(s)
            if !m.stale.isEmpty { problems.append("\(label): icons for windows not on screen \(m.stale) \(barText(s))") }
            if !m.missing.isEmpty { problems.append("\(label): on-screen test windows with no icon \(m.missing)") }
        }
        for round in 1...rounds {
            let first = switchDesktop(other)
            if case .unsupported(let why) = first, round == 1 { return .skip("Mission Control's desktop buttons not found: \(why)") }
            guard case .done(let t1) = first else { problems.append("round \(round): could not switch to desktop \(other)"); break }
            if let dw = d {
                let seen = watch([Expect("away", t1, 300, .state { !$0.has(a.number) && $0.has(dw.number) })])
                if let l = seen[0].latencyMs { away.append(l) } else { problems.append("round \(round): desktop \(other) not shown \(barText())") }
            } else {
                let seen = watch([Expect("away", t1, 300, .state { !$0.has(a.number) })])
                if let l = seen[0].latencyMs { away.append(l) } else { problems.append("round 1: A still shown after leaving its desktop \(barText())") }
                sleepMs(300)
                let dw = try open("D", in: app)
                d = dw
                let s2 = watch([Expect("D appears", dw.openedAt, 400, .state { $0.has(dw.number) })])
                dAppear = s2[0].latencyMs
                if dAppear == nil { problems.append("D never appeared on desktop \(other)") }
            }
            checkSettled("round \(round) on desktop \(other)")
            guard let t2 = goToDesktop(home) else { problems.append("round \(round): could not switch back to desktop \(home)"); break }
            let dn = d?.number ?? 0
            let seen = watch([Expect("back", t2, 300, .state { $0.has(a.number) && !$0.has(dn) })])
            if let l = seen[0].latencyMs { back.append(l) } else { problems.append("round \(round): home desktop not shown \(barText())") }
            checkSettled("round \(round) on desktop \(home)")
        }
        if d != nil { close("D") }
        let slow = (away + back).filter { $0 > 300 }
        if !slow.isEmpty { problems.append("\(slow.count) switch(es) took over 300 ms") }
        let timing = "leave \(pctText(away)); return \(pctText(back))" + (dAppear.map { "; D appeared in \(msText($0))" } ?? "")
        let metrics: [String: Any] = ["awayMs": away.map(round1), "backMs": back.map(round1), "dAppearMs": orNull(dAppear.map(round1))]
        return problems.isEmpty ? .pass(timing, "\(rounds) round trips, desktops \(home) and \(other)", metrics)
                                : .fail(problems.joined(separator: "; ") + " [\(timing)]", metrics)
    }

    // MARK: - T20 resting pointer

    /// T20: the pointer rests on C's icon (test app 2) while test app 1 opens
    /// B, which shifts the icons under it. The hover, the tooltip and a click
    /// without moving must all follow the icon now under the pointer.
    func t20() throws -> Outcome {
        let app1 = try app("app1")
        _ = try ensure("A", in: app1, shown: true)
        if wins["B"] != nil { close("B"); sleepMs(300) }
        let app2 = try app("app2")
        let c = try ensure("C", in: app2, shown: true)
        Mouse.save()
        defer { Mouse.restore() }
        clearHover()
        let p = try target(c)
        Mouse.move(to: p)
        guard settle(after: 0, timeoutMs: 1500, pokeEveryMs: nil, { $0.tipShows(c.number) }) != nil else {
            return .fail("setup: resting on C never showed its tooltip (\(reader.latest?.tipText ?? "?"))")
        }
        let b = try open("B", in: app1)
        guard settle(after: b.openedAt, timeoutMs: 2000, pokeEveryMs: nil, { $0.has(b.number) }) != nil else {
            return .fail("B never appeared")
        }
        sleepMs(150)
        guard let s = reader.read() else { return .fail("no state") }
        guard let under = s.buttons.first(where: { $0.frame.rect.insetBy(dx: -0.01, dy: -0.01).contains(p) }) else {
            return .inconclusive("no icon under the pointer after the shift \(barText(s))")
        }
        var problems: [String] = []
        let shifted = under.windowId != c.number
        if under.hovered != true { problems.append("#\(under.windowId) is under the pointer but not marked hovered") }
        if s.buttons.contains(where: { $0.hovered == true && $0.windowId != under.windowId }) { problems.append("another icon is marked hovered") }
        if !s.tipShows(under.windowId) { problems.append("tooltip is \(s.tipText), pointer is over #\(under.windowId)") }

        // A click without moving raises the window under the pointer.
        guard testPids.contains(under.pid) else { return .inconclusive("the icon under the pointer is not a test app's") }
        if case .element(let pid, _) = axHitTest(p), pid != s.pid { return .inconclusive("WindowStrip is not on top at the pointer") }
        let downAt = nowNs()
        Mouse.post(.leftMouseDown, at: p)
        sleepMs(30)
        Mouse.post(.leftMouseUp, at: p)
        let seen = watch([Expect("raised", downAt, 400, .live { frontLayer0()?.id == under.windowId })])
        if seen[0].latencyMs == nil { problems.append("the click did not bring #\(under.windowId) to the front (front is \(frontLayer0()?.label ?? "?"))") }
        let detail = "icons \(shifted ? "shifted" : "did not shift"); under the pointer: \(tags([under.windowId]))"
        let timing = seen[0].latencyMs.map { "raise \(msText($0))" }
        return problems.isEmpty ? .pass(timing, detail) : .fail(problems.joined(separator: "; ") + " [\(detail)]")
    }

    // MARK: - T21 hung app

    /// T21: test app 1 stops answering for 4 s. Meanwhile test app 2's new
    /// window must appear, a click on app 1's icon must not hold up a click on
    /// app 2's icon, and the bar's main thread must not stall.
    func t21() throws -> Outcome {
        let app1 = try app("app1")
        let a = try ensure("A", in: app1, shown: true)
        let app2 = try app("app2")
        let c = try ensure("C", in: app2, shown: true)
        let r = try app1.send("hang 4000")
        let hungAt = app1.at(r)
        defer { _ = pollUntil(6000, everyMs: 50) { (try? app1.status(timeoutMs: 200)) != nil } }
        sleepMs(150)
        let e = try open("E", in: app2)
        let appear = watch([Expect("E appears", e.openedAt, 400, .state { $0.has(e.number) })])
        _ = try click(a)
        let clickC = try click(c)
        let raise = watch([Expect("C in front", clickC, 400, .live { frontLayer0()?.id == c.number })])
        let stalls = (reader.read()?.stalls ?? []).filter { $0.atUptimeNs.value >= hungAt && $0.ms >= 100 }
        close("E")
        var problems: [String] = []
        if let l = appear[0].latencyMs { if l > 400 { problems.append("E appeared after \(msText(l))") } } else { problems.append("E never appeared") }
        if let l = raise[0].latencyMs { if l > 400 { problems.append("C came to the front after \(msText(l))") } }
        else { problems.append("C never came to the front (front is \(frontLayer0()?.label ?? "?"))") }
        if !stalls.isEmpty { problems.append("\(stalls.count) main-thread stall(s), max \(msText(stalls.map(\.ms).max()!))") }
        let timing = "E appeared \(appear[0].latencyMs.map(msText) ?? "never"), C raised \(raise[0].latencyMs.map(msText) ?? "never")"
        return problems.isEmpty ? .pass(timing, "no stalls while app 1 was hung") : .fail(problems.joined(separator: "; ") + " [\(timing)]")
    }

    // MARK: - T22 overflow

    /// T22: 26 windows on one desktop. Icons shrink to fit, never overlap each
    /// other or the island, and the ones that can't fit are left out and
    /// logged.
    func t22() throws -> Outcome {
        let app1 = try app("app1")
        let logStart = log.size()
        var opened: [Win] = []
        defer { for w in opened { close(w.tag) } }
        for i in 1...26 {
            let rect = CGRect(x: 60 + Double(i % 9) * 34, y: 110 + Double(i % 7) * 30, width: 240, height: 150)
            opened.append(try open("W\(i)", rect: rect, in: app1))
        }
        sleepMs(1200)
        guard let s = settle(after: opened.last!.openedAt, timeoutMs: 2000, { _ in true }) else { return .fail("no state after opening") }
        var problems: [String] = []
        var shown = 0, slotWidth = 0.0
        let mine = Set(opened.map(\.number))
        for panel in s.panels {
            let b = panel.buttons.sorted { $0.frame.x < $1.frame.x }
            shown += b.filter { mine.contains($0.windowId) }.count
            slotWidth = b.map(\.frame.w).min() ?? 0
            for (prev, next) in zip(b, b.dropFirst()) where next.frame.x < prev.frame.x + prev.frame.w - 0.5 {
                problems.append("#\(prev.windowId) and #\(next.windowId) overlap")
            }
            if let w = b.map(\.frame.w).min(), w < 17.5 { problems.append("an icon is only \(trim(w)) pt wide") }
            let limit = panel.iconAreaMaxX.map { $0 + panel.frame.x } ?? panel.frame.rect.maxX
            if let maxX = b.map({ $0.frame.rect.maxX }).max(), maxX > limit + 0.5 {
                problems.append("icons reach x \(trim(maxX)), past the icon area's end \(trim(limit))")
            }
        }
        let leftOut = log.lines(since: logStart).parsed.contains { $0.tag == "render" && $0.message.contains("left out") }
        if shown < 26 && !leftOut { problems.append("\(26 - shown) windows have no icon and no 'left out' log line") }
        let detail = "\(shown) of 26 shown, narrowest slot \(trim(slotWidth)) pt\(leftOut ? ", some windows left out and logged" : "")"
        return problems.isEmpty ? .pass(nil, detail, ["shown": shown, "slot": slotWidth]) : .fail(problems.joined(separator: "; ") + " [\(detail)]")
    }

    // MARK: - T23 soak

    /// T23: 15 rounds of launching a test app, opening and closing three
    /// windows, and quitting it. WindowStrip's memory, thread count and helper
    /// count stay flat, and the bar ends with no test windows.
    func t23() throws -> Outcome {
        let pid = try state().pid
        func rssMB() -> Double { (Double(runTool("/bin/ps", ["-o", "rss=", "-p", "\(pid)"]).out) ?? 0) / 1024 }
        func threads() -> Int { max(0, runTool("/bin/ps", ["-M", "-p", "\(pid)"]).out.split(separator: "\n").count - 1) }
        func helpers() -> Int { runTool("/usr/bin/pgrep", ["-x", "wslist"]).out.split(separator: "\n").count }
        var soakPids = Set<Int32>()
        func round(_ n: Int) throws -> Bool {
            let app = try app("soak")
            soakPids.insert(app.pid)
            var ws: [Win] = []
            for (i, t) in ["X1", "X2", "X3"].enumerated() {
                ws.append(try open(t, rect: CGRect(x: 200 + Double(i) * 40, y: 200 + Double(i) * 30, width: 260, height: 160), in: app))
            }
            let ok = settle(after: ws.last!.openedAt, timeoutMs: 2000, pokeEveryMs: nil, { s in ws.allSatisfy { s.has($0.number) } }) != nil
            for w in ws { close(w.tag) }
            quitApp("soak")
            return ok
        }
        _ = try round(0)     // warm-up: first launch costs are not leaks
        sleepMs(500)
        let rss0 = rssMB(), threads0 = threads()
        var missed = 0
        for n in 1...15 { if try !round(n) { missed += 1 } }
        sleepMs(1500)
        let rss1 = rssMB(), threads1 = threads(), helperCount = helpers()
        let leftovers = (try? freshState())?.buttons.filter { soakPids.contains($0.pid) || NSRunningApplication(processIdentifier: $0.pid) == nil } ?? []
        var problems: [String] = []
        if missed > 0 { problems.append("\(missed) round(s) where the three windows did not all appear within 2 s") }
        if rss1 - rss0 > 8 { problems.append("memory grew \(String(format: "%.1f", rss1 - rss0)) MB") }
        if threads1 > threads0 + 3 { problems.append("threads went from \(threads0) to \(threads1)") }
        if helperCount != 1 { problems.append("\(helperCount) wslist helpers running") }
        if !leftovers.isEmpty { problems.append("\(leftovers.count) icon(s) left for quit test apps") }
        let detail = String(format: "memory %.1f → %.1f MB, threads %d → %d, helpers %d", rss0, rss1, threads0, threads1, helperCount)
        let metrics: [String: Any] = ["rssBeforeMB": round1(rss0), "rssAfterMB": round1(rss1), "threadsBefore": threads0, "threadsAfter": threads1]
        return problems.isEmpty ? .pass("15 rounds", detail, metrics) : .fail(problems.joined(separator: "; ") + " [\(detail)]", metrics)
    }

    // MARK: - T24 restart

    /// T24: after WindowStrip restarts, the strip comes back under the notch
    /// island (when one is on screen) and its icons stay clear of it (T03's
    /// checks on the new process).
    func t24() throws -> Outcome {
        let before = try state().pid
        let t0 = nowNs()
        let r = runTool("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/dev.windowstrip"])
        guard r.status == 0 else { return .inconclusive("launchctl kickstart failed: \(r.out)") }
        guard settle(after: t0, timeoutMs: 10_000, pokeEveryMs: 1000, { $0.pid != before }) != nil else {
            return .fail("no state.json from a new WindowStrip within 10 s")
        }
        sleepMs(1500)
        let o = try t03()
        if o.status == .pass { return .pass("restarted", o.detail) }
        return o
    }

    // MARK: - T25 raise z-order

    /// T25: with C (test app 2) above A above B (test app 1), clicking B's
    /// icon must give B > C > A: only B comes forward and A stays behind C
    /// the whole time.
    func t25() throws -> Outcome {
        let app1 = try app("app1")
        let a = try ensure("A", in: app1, shown: true)
        let b = try ensure("B", in: app1, shown: true)
        let app2 = try app("app2")
        let c = try ensure("C", in: app2, shown: true)
        let ids = [a.number, b.number, c.number]
        func order() -> [UInt32] { cgWindows().filter { ids.contains($0.id) }.map(\.id) }
        try app1.send("focus B")
        sleepMs(100)
        let ra = try app1.send("focus A")
        _ = makeActive(app1, event: app1.at(ra))
        sleepMs(100)
        let rc = try app2.send("focus C")
        _ = makeActive(app2, event: app2.at(rc))
        guard pollUntil(1500, { order() == [c.number, a.number, b.number] }) else {
            return .inconclusive("setup: order is \(tags(order())), wanted C > A > B")
        }
        sleepMs(150)
        let clickAt = try click(b)
        let want = [b.number, c.number, a.number]
        var reached: Double?, aAboveC: Double?, keyB: Double?
        let end = clickAt + ns(900)
        while nowNs() < end {
            let o = order()
            let t = msFrom(clickAt, to: nowNs())
            if reached == nil, o == want { reached = t }
            if aAboveC == nil, let ia = o.firstIndex(of: a.number), let ic = o.firstIndex(of: c.number), ia < ic { aAboveC = t }
            if keyB == nil, let st = try? app1.status(timeoutMs: 300), st.active, st.keyTag == "B" { keyB = t }
            if reached != nil, keyB != nil, t > 400 { break }
            sleepMs(5)
        }
        var problems: [String] = []
        if let t = reached { if t > 400 { problems.append("B > C > A took \(msText(t))") } }
        else { problems.append("never reached B > C > A (order now \(tags(order())))") }
        if let t = aAboveC { problems.append("A came above C at \(msText(t)) (the app's other window jumped)") }
        if keyB == nil { problems.append("B never became key in an active app") }
        let timing = "B > C > A at \(reached.map(msText) ?? "never"), B key at \(keyB.map(msText) ?? "never")"
        return problems.isEmpty ? .pass(timing, "A stayed behind C") : .fail(problems.joined(separator: "; ") + " [\(timing)]")
    }

    // MARK: - T26 late raise

    /// T26: test app 1 is busy for 400 ms right after its icon is clicked,
    /// and test app 2's icon is clicked meanwhile. When app 1 catches up and
    /// carries out the older raise, app 2's window must end up in front.
    func t26() throws -> Outcome {
        let app1 = try app("app1")
        let a = try ensure("A", in: app1, shown: true)
        let app2 = try app("app2")
        let c = try ensure("C", in: app2, shown: true)
        let rc = try app2.send("focus C")
        _ = makeActive(app2, event: app2.at(rc))
        Mouse.save()
        defer { Mouse.restore() }
        clearHover()
        let pa = try target(a), pc = try target(c)
        Mouse.move(to: pa)
        sleepMs(250)                        // the hover's title read is done
        _ = try app1.send("hang 400")       // it answers, then blocks its main thread
        Mouse.post(.leftMouseDown, at: pa)
        sleepMs(20)
        Mouse.post(.leftMouseUp, at: pa)
        sleepMs(100)
        Mouse.move(to: pc)
        sleepMs(20)
        let downC = nowNs()
        Mouse.post(.leftMouseDown, at: pc)
        sleepMs(20)
        Mouse.post(.leftMouseUp, at: pc)
        var cFront: Double?, aOnTop: Double?
        let end = downC + ns(1500)
        while nowNs() < end {
            let t = msFrom(downC, to: nowNs())
            let f = frontLayer0()?.id
            if cFront == nil, f == c.number { cFront = t }
            if cFront != nil, aOnTop == nil, f == a.number { aOnTop = t }
            sleepMs(10)
        }
        let final = frontLayer0()
        _ = pollUntil(2000, everyMs: 50) { (try? app1.status(timeoutMs: 200)) != nil }
        var problems: [String] = []
        if cFront == nil { problems.append("C never came to the front") }
        if final?.id != c.number { problems.append("1.5 s after the click on C the front window is \(final?.label ?? "none")") }
        let detail = "C in front at \(cFront.map(msText) ?? "never")"
            + (aOnTop.map { "; A landed on top at \(msText($0))" } ?? "; A never landed on top")
        return problems.isEmpty ? .pass(nil, detail) : .fail(problems.joined(separator: "; ") + " [\(detail)]")
    }

    // MARK: - T27 full screen

    /// T27: test window A goes full screen. While its Space shows, the strip
    /// is hidden (transparent); once A leaves full screen, the strip is back,
    /// and on every desktop, not only this one (it once wasn't).
    func t27() throws -> Outcome {
        let app1 = try app("app1")
        let a = try ensure("A", in: app1, shown: true)
        let s = try state()
        guard let f = s.panels.first?.frame else { return .inconclusive("state.json has no strip") }
        let pid = s.pid, repairsBefore = s.desktopRepairs ?? 0
        func stripOnScreen() -> Bool { shownStrip(pid: pid, at: f) != nil }
        guard currentSpaceType() == 0, stripOnScreen() else { return .inconclusive("not on a desktop with the strip showing") }
        let rf = try app1.send("focus A")
        _ = makeActive(app1, event: app1.at(rf))
        _ = try app1.send("fullscreen A")
        defer {
            if currentSpaceType() == 4 {
                _ = try? app1.send("fullscreen A")
                _ = pollUntil(5000, everyMs: 50) { currentSpaceType() == 0 }
                sleepMs(500)
            }
        }
        guard pollUntil(5000, everyMs: 10, { currentSpaceType() == 4 }) else { return .inconclusive("A did not go full screen") }
        let entered = nowNs()
        let hidden = pollUntil(1500, everyMs: 10) { !stripOnScreen() }
        let hideMs = msFrom(entered, to: nowNs())
        sleepMs(700)    // the full-screen animation settles; the strip must stay away
        let stayedHidden = !stripOnScreen()
        _ = try app1.send("fullscreen A")
        guard pollUntil(5000, everyMs: 10, { currentSpaceType() == 0 }) else { return .fail("A did not leave full screen") }
        let left = nowNs()
        let shown = pollUntil(1500, everyMs: 10) { stripOnScreen() }
        let showMs = msFrom(left, to: nowNs())
        sleepMs(600)    // A's window finishes shrinking back before the next test
        var problems: [String] = []
        if !hidden { problems.append("the strip stayed on screen over the full-screen window") }
        else if !stayedHidden { problems.append("the strip came back while A was still full screen") }
        if !shown { problems.append("the strip did not come back after A left full screen") }
        // On every desktop: at once, or after WindowStrip's check 1.5 s after
        // full screen ends rebuilds the panels (a new window number).
        let desktops = notchDesktops()
        if shown, desktops.count > 1 {
            func stripSpaces() -> Set<UInt64> { reader.read()?.panels.first?.windowNumber.map { spacesOf(UInt32($0)) } ?? [] }
            if !pollUntil(2500, everyMs: 20, { desktops.isSubset(of: stripSpaces()) }) {
                problems.append("the strip came back on Spaces \(stripSpaces().sorted()) only, not every desktop \(desktops.sorted())")
            }
        }
        let repaired = (reader.read()?.desktopRepairs ?? repairsBefore) - repairsBefore
        _ = a
        let detail = "hidden \(hidden ? msText(hideMs) : "never") after the full-screen Space showed, back \(shown ? msText(showMs) : "never") after it left"
            + (repaired > 0 ? "; it came back on one desktop only and WindowStrip rebuilt it" : "")
        return problems.isEmpty ? .pass(nil, detail) : .fail(problems.joined(separator: "; ") + " [\(detail)]")
    }

    // MARK: - T28 every desktop

    /// WindowStrip's shown strip on this desktop: its window at the strip's
    /// place, not transparent (any window number: a repair makes a new one).
    func shownStrip(pid: Int32, at f: Box) -> CGWin? {
        cgWindows().first { $0.pid == pid && $0.layer > 0 && $0.alpha > 0
            && abs($0.bounds.minX - f.x) < 1 && abs($0.bounds.width - f.w) < 1 }
    }

    /// T28: the strip drops off the other desktops, as it once did after a
    /// full-screen app (the bar was then missing there). WindowStrip's test hook clears its
    /// "every Space" flag, which leaves it on this desktop only. After a
    /// switch to another desktop a strip must show there within 2.5 s (a new
    /// one: WindowStrip rebuilds its panels once the switch settles), be on
    /// every desktop, and still show after the switch back. The test turns
    /// the hook on and removes the setting after; if the strip is still on
    /// one desktop at the end, it restarts WindowStrip.
    func t28() throws -> Outcome {
        let desktops = notchDesktops()
        guard desktops.count >= 2 else { return .skip("only one desktop") }
        let s = try state()
        guard let first = s.panels.first, let n = first.windowNumber, n > 0 else { return .inconclusive("state.json has no strip window number") }
        let strip = UInt32(n), f = first.frame, pid = s.pid, repairsBefore = s.desktopRepairs ?? 0
        guard currentSpaceType() == 0, shownStrip(pid: pid, at: f)?.id == strip, let here = desktop(), here.count >= 2 else {
            return .inconclusive("not on a desktop with the strip showing")
        }
        guard desktops.isSubset(of: spacesOf(strip)) else {
            return .fail("the strip was on Spaces \(spacesOf(strip).sorted()) only before the test, not every desktop \(desktops.sorted())")
        }
        let home = here.index, other = home < here.count ? home + 1 : home - 1
        setTestHooks(true)
        defer {
            setTestHooks(false)
            let now = reader.read()?.panels.first?.windowNumber.map { spacesOf(UInt32($0)) } ?? []
            if !desktops.isSubset(of: now) {
                warn("T28 left the strip on Spaces \(now.sorted()) only; restarting WindowStrip")
                _ = runTool("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/dev.windowstrip"])
                sleepMs(2500)
            }
        }
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("dev.windowstrip.test.dropEveryDesktop"),
                                                                     object: nil, userInfo: nil, deliverImmediately: true)
        guard pollUntil(1000, everyMs: 2, { !desktops.isSubset(of: spacesOf(strip)) }) else {
            return .skip("WindowStrip's test hook did nothing (an older build, or it didn't see the testHooks setting)")
        }
        var problems: [String] = []
        var detail = ""
        switch switchDesktop(other) {
        case .unsupported(let why):
            return .skip("can't switch desktops (\(why))")
        case .failed:
            return .fail("could not switch to desktop \(other)")
        case .done(let at):
            var arrived: CGWin?
            _ = pollUntil(2500, everyMs: 5) {
                guard let w = shownStrip(pid: pid, at: f), let now = currentSpace(), spacesOf(w.id).contains(now) else { return false }
                arrived = w
                return true
            }
            if let w = arrived {
                detail = "a strip showed on desktop \(other) \(msText(msFrom(at, to: nowNs()))) after the switch"
                if w.id == strip { problems.append("the strip on desktop \(other) is the old window, so nothing was rebuilt") }
                if !desktops.isSubset(of: spacesOf(w.id)) {
                    problems.append("the strip on desktop \(other) is on Spaces \(spacesOf(w.id).sorted()) only, not every desktop \(desktops.sorted())")
                }
            } else {
                problems.append("no strip on desktop \(other) 2.5 s after the switch")
            }
            if goToDesktop(home) == nil {
                problems.append("could not switch back to desktop \(home)")
            } else if !pollUntil(1500, everyMs: 10, { shownStrip(pid: pid, at: f) != nil }) {
                problems.append("no strip back on desktop \(home)")
            }
        }
        let repaired = (reader.read()?.desktopRepairs ?? repairsBefore) - repairsBefore
        detail += (detail.isEmpty ? "" : "; ") + "\(repaired) rebuild\(repaired == 1 ? "" : "s")"
        if repaired != 1 { problems.append("WindowStrip rebuilt its panels \(repaired) times, not once") }
        return problems.isEmpty ? .pass(nil, detail) : .fail(problems.joined(separator: "; ") + " [\(detail)]")
    }
}
