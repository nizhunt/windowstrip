// Decides which windows the bar shows and keeps it current.
//
// The window server's list (CGWindowList) says which windows are on screen on
// the current Space; AX facts from the worker say which of those are real
// windows. Updates are driven by AX notifications and workspace events, with
// a 2 s poll as a safety net. Closing and minimising remove the icon at the
// AX event, before the window server's list catches up after the animation.

import AppKit

final class Controller: NSObject, StripViewDelegate {
    private let ownPid = ProcessInfo.processInfo.processIdentifier
    private let tooltip = Tooltip()
    private let stalls = RunLoopStallMonitor()
    private var panels: [CGDirectDisplayID: StripPanel] = [:]
    private var views: [CGDirectDisplayID: StripView] = [:]

    // What AX knows.
    private var trusted = false
    private var facts: [CGWindowID: WindowFacts] = [:]
    private var appFacts: [pid_t: AppFacts] = [:]
    /// Windows AX reported closed or minimised, kept off the bar while the
    /// window server still shows them animating away.
    private var tombstones: [CGWindowID: UInt64] = [:]
    private var hiddenApps: [pid_t: UInt64] = [:]
    /// On-screen windows with no AX facts yet, and since when.
    private var unknownSince: [CGWindowID: UInt64] = [:]
    private var observeAsked: [pid_t: UInt64] = [:]
    private var reportedRejects = Set<CGWindowID>()

    // Order: apps by when they were first seen (kept across restarts), windows
    // inside an app by when they were first seen, so icons move as little as
    // possible.
    private var appOrder: [String] = UserDefaults.standard.stringArray(forKey: "appOrder") ?? []
    private var appRank: [String: Int] = [:]
    private var firstSeen: [CGWindowID: Int] = [:]
    private var seenCounter = 0

    private struct AppInfo { let name: String; let key: String; let regular: Bool; let bundleID: String?; let checkedAt: UInt64 }
    private var appInfo: [pid_t: AppInfo] = [:]
    private var icons: [String: NSImage] = [:]

    // The notch.
    private var caps: [CGDirectDisplayID: CGFloat] = [:]
    private var displayUUID: [CGDirectDisplayID: String] = [:]
    /// Black covers right of the notch, over app menus that spill past it
    /// (a long menu list, such as a browser's), up to where they end.
    private var covers: [CGDirectDisplayID: StripPanel] = [:]
    private var coverArea: [CGDirectDisplayID: NSRect] = [:]
    private var menuEnd: [CGDirectDisplayID: CGFloat] = [:]
    /// The app whose menus `menuEnd` describes; until the front app's menus
    /// are read, the poll asks again (for 10 s after a switch).
    private var menuOwner: pid_t?
    private var menuRetryUntil: UInt64 = 0
    /// Displays whose strip is off screen because a full-screen app shows there.
    private var hiddenForFullScreen = Set<CGDirectDisplayID>()
    private var neighbours: [Neighbour] = []
    private var lastRepair: UInt64 = 0
    private var repairs = 0

    // Refreshing.
    private var scheduled = Set<UInt64>()
    private var lastSignature = ""
    private var pollTimer: Timer?
    private var polls = 0

    // The window server's list comes from a helper process (WindowLister): the
    // call blocks for 300-400 ms while a window minimises and, in this
    // process, holds the lock every redraw needs. Events are shown at once on
    // the last list; a new list follows.
    private let lister = WindowLister()
    private var lastList: [CGWin] = []
    /// When the fetch that produced `lastList` started.
    private var lastListAt: UInt64 = 0
    private var listInFlight = false
    private var listPending: String?
    private var listTimes = Ring(capacity: 200)
    /// The window AX last reported focused, used for the front highlight
    /// until a window list taken after that event confirms the order.
    private var focusHint: (pid: pid_t, id: CGWindowID, at: UInt64)?

    // Interaction.
    private var hoveredID: CGWindowID?
    private var hideWork: DispatchWorkItem?
    private var optimistic: (id: CGWindowID, until: UInt64)?
    private var lastRaise: [String: Any] = [:]
    /// Counts clicks, so a raise can tell a newer click came after it.
    private var clickSeq = 0
    private var latestClick: (w: WinInfo, start: UInt64, seq: Int)?
    /// Raises that may still put their window in front after a newer click,
    /// one per app, until the time given (see `watchIfLate`).
    private var lateRaises: [pid_t: (w: WinInfo, seq: Int, until: UInt64)] = [:]
    /// The last click counted as a failed raise (one click can be checked twice).
    private var failedSeq = 0
    private var spaceChangedAt: UInt64 = 0
    /// Each display's desktop in Mission Control's order (by display UUID, or
    /// "Main"), and which way the last list moved it: the strip slides along.
    private var spacePositions: [String: Int] = [:]
    private var slides: [CGDirectDisplayID: Int] = [:]

    // Browser windows' site icons (Tabs.swift).
    private let tabReader = TabReader()
    private var tabIcons: [CGWindowID: TabIcons] = [:]
    /// Browser windows that got a read of their tabs since they appeared.
    private var tabTried = Set<CGWindowID>()
    /// Reads asked for a browser window that no read has matched yet (one
    /// during a desktop switch sees frames on the move): three at most.
    private var tabAttempts: [CGWindowID: Int] = [:]
    /// `unchanged`: reads in a row that changed nothing (a page whose title
    /// ticks every second).
    private struct TabReads { var planned = false; var running = false; var again = false; var last: UInt64 = 0; var unchanged = 0 }
    private var tabReads: [pid_t: TabReads] = [:]
    /// Browser windows whose tabs may have changed while no showing strip had
    /// them: read when they show up.
    private var tabStale = Set<CGWindowID>()
    /// Width each display's icons need, from the last render: an island that
    /// changes width only matters when the icons don't fit under it.
    private var neededWidth: [CGDirectDisplayID: CGFloat] = [:]

    // Numbers for the log and the state file.
    private var refreshTimes = Ring(capacity: 200)
    private var minute = (refreshes: 0, renders: 0, clicks: 0, raiseFails: 0, hovers: 0)
    private var stateSeq = 0

    // MARK: - Start

    func start() {
        for (i, key) in appOrder.enumerated() { appRank[key] = i }
        stalls.start()
        axWorker.onUpdate = { [weak self] in self?.apply($0) }
        axWorker.onTitleChange = { [weak self] in self?.titleChanged($0, window: $1, title: $2) }
        axWorker.start()
        trusted = AXIsProcessTrusted()
        Log.info("start", "WindowStrip 2 pid=\(ownPid) trusted=\(trusted) windowServerRaise=\(Raiser.hasWindowServerCalls) verbose=\(Log.verbose) screens: \(screenSummary())")

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appTerminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appHiddenOrShown(_:)), name: NSWorkspace.didHideApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appHiddenOrShown(_:)), name: NSWorkspace.didUnhideApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(woke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(woke), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(asleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(asleep), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(refreshRequested), name: Notification.Name("dev.windowstrip.refresh"), object: nil)
        if UserDefaults.standard.bool(forKey: "snapshots") {
            // Off by default: the tooltip picture can show a window title.
            dnc.addObserver(self, selector: #selector(snapshotRequested), name: Notification.Name("dev.windowstrip.snapshot"), object: nil)
        }
        dnc.addObserver(self, selector: #selector(asleep), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(woke), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        startPolling()

        // One list up front, on this thread, so the first panels know where
        // the island is.
        lastListAt = uptimeNs()
        lastList = onScreenWindows()
        if trusted { observeRegularApps() } else { promptForAccessibility() }
        buildPanels()
        refresh("start")
        checkMenuBar()
    }

    private func observeRegularApps() {
        let pids = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier)
        axWorker.observe(pids)
    }

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Events

    @objc private func spaceChanged() {
        Log.debug("event", "space changed")
        spaceChangedAt = uptimeNs()
        // A window that comes forward from now on may be on this Space for
        // reasons that have nothing to do with an earlier click.
        lateRaises = [:]
        // The last list is the old Space's, so don't show it again: fetch.
        requestList("space")
        schedule("space", [0.1, 0.25, 0.6])
    }

    /// Refreshes after something that will change the window server's list
    /// within a few hundred ms (an unhide, a restore): dense at first, so the
    /// icon follows the window as soon as it is listed.
    private static let settleDelays: [Double] = [0, 0.04, 0.08, 0.12, 0.16, 0.2, 0.3, 0.45, 0.7]

    @objc private func appActivated() {
        schedule("activate", [0, 0.25])
        menuRetryUntil = uptimeNs() + 10_000_000_000
        // An app that is still launching may add its menus a moment later.
        checkMenuBar()
        for delay in [0.3, 1.0] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.checkMenuBar() } }
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        appInfo[app.processIdentifier] = nil
        Log.debug("event", "launched \(app.localizedName ?? "?") pid \(app.processIdentifier)")
        if trusted && app.activationPolicy == .regular { axWorker.observe([app.processIdentifier]) }
        // A new app's first window shows up before the app answers AX, so
        // look often for the first second and a half.
        schedule("launch", [0.05, 0.1, 0.15, 0.2, 0.3, 0.45, 0.6, 1.0, 1.5])
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pid = app.processIdentifier
        Log.debug("event", "quit \(app.localizedName ?? "?") pid \(pid)")
        appInfo[pid] = nil
        hiddenApps[pid] = nil
        observeAsked[pid] = nil
        tabReads[pid] = nil
        axWorker.forget(pid)
        schedule("quit", [0, 0.3])
    }

    @objc private func appHiddenOrShown(_ note: Notification) {
        let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
        if note.name == NSWorkspace.didHideApplicationNotification {
            if let pid { hiddenApps[pid] = uptimeNs() + 1_500_000_000 }
            schedule("hide", [0, 0.3, 1.0])
        } else {
            if let pid { hiddenApps[pid] = nil }
            schedule("unhide", Controller.settleDelays)
        }
    }

    @objc private func woke() {
        Log.info("event", "wake")
        startPolling()
        schedule("wake", [0.5, 2])
    }

    /// Screens off, locked, or another user's session: nothing to show, so
    /// the 2 s poll stops until the wake (events still update the bar).
    @objc private func asleep() {
        guard let timer = pollTimer else { return }
        timer.invalidate()
        pollTimer = nil
        Log.info("event", "screens asleep or locked: polling paused")
    }

    private func startPolling() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 2.0, target: self, selector: #selector(poll), userInfo: nil, repeats: true)
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    @objc private func screensChanged() {
        Log.info("screens", screenSummary())
        buildPanels()
        refresh("screens")
    }

    @objc private func refreshRequested() {
        lastSignature = ""
        refresh("requested")
    }

    @objc private func poll() {
        polls += 1
        if polls % 5 == 0 { checkTrust() }
        if polls % 15 == 0 { prune() }
        if polls % 30 == 0 { logMinute() }
        if polls % 8 == 0 {
            readShownBrowsers()
            checkMenuBar()
        } else if menuOwner != NSWorkspace.shared.frontmostApplication?.processIdentifier, uptimeNs() < menuRetryUntil {
            checkMenuBar()
        }
        // The state file is written when the bar changes, not on every poll.
        requestList("poll")
    }

    private func checkTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        trusted = now
        Log.info("ax", "Accessibility is now \(now ? "granted" : "revoked")")
        if now {
            axWorker.reset()
            observeAsked = [:]
            observeRegularApps()
        }
        lastSignature = ""
    }

    /// Forgets windows that no longer exist anywhere (on any Space).
    private func prune() {
        let asked = uptimeNs()
        let lastSeenNumber = seenCounter
        lister.request(.all) { [weak self] reply in
            guard let self, !reply.ids.isEmpty else { return }
            let existing = reply.ids
            // A window first seen after the request may be missing from the
            // list only because it is newer: keep it.
            axWorker.prune(keeping: existing, listedAt: asked)
            self.firstSeen = self.firstSeen.filter { existing.contains($0.key) || $0.value > lastSeenNumber }
            self.tombstones = self.tombstones.filter { existing.contains($0.key) }
            self.tabIcons = self.tabIcons.filter { existing.contains($0.key) }
            self.tabTried = self.tabTried.filter { existing.contains($0) }
            self.tabAttempts = self.tabAttempts.filter { existing.contains($0.key) }
            self.tabStale = self.tabStale.filter { existing.contains($0) }
            self.reportedRejects = self.reportedRejects.filter { existing.contains($0) }
        }
    }

    private func logMinute() {
        axWorker.logStats()
        let m = minute
        if m.refreshes > 0 {
            Log.info("stats", "last minute: \(m.refreshes) refreshes (p50 \(ms(refreshTimes.percentile(0.5))), p95 \(ms(refreshTimes.percentile(0.95))), max \(ms(refreshTimes.max))), window lists p95 \(ms(listTimes.percentile(0.95))) max \(ms(listTimes.max)), \(m.renders) changes, \(m.hovers) hovers, \(m.clicks) clicks, \(m.raiseFails) failed raises, \(repairs) notch repairs, \(stalls.recent.count) stalls so far")
        }
        minute = (0, 0, 0, 0, 0)
        repairs = 0
    }

    // MARK: - AX updates

    private func apply(_ update: AXUpdate) {
        facts = update.facts
        appFacts = update.apps
        let now = uptimeNs()
        switch update.event {
        case .closed(let id)?:
            tombstones[id] = now + 1_500_000_000
            schedule(update.reason, [0, 0.3, 1.0])
        case .minimized(let id)?:
            tombstones[id] = now + 1_500_000_000
            schedule(update.reason, [0, 1.0])
        case .restored(let id)?:
            tombstones[id] = nil
            schedule(update.reason, Controller.settleDelays + [1.0])
        case .hidden(let pid)?:
            hiddenApps[pid] = now + 1_500_000_000
            schedule(update.reason, [0, 1.0])
        case .shown(let pid)?:
            hiddenApps[pid] = nil
            schedule(update.reason, Controller.settleDelays)
        case .created(let id, _)?:
            unknownSince[id] = nil
            schedule(update.reason, [0, 0.03, 0.08, 0.15, 0.3, 1.0])
        case .focused(let id, let pid)?:
            if let id { focusHint = (pid, id, now) }
            schedule(update.reason, [0, 0.05, 0.25])
        case nil:
            // New facts only: the last list is enough.
            Activity.run("apply(\(update.reason))") { applyList(update.reason) }
        }
    }

    // MARK: - Refresh

    /// A delay of 0 refreshes now; each later one asks for a new window list
    /// then. Requests due within 15 ms of one already planned are merged.
    private func schedule(_ reason: String, _ delays: [Double]) {
        let now = uptimeNs()
        for delay in delays {
            if delay <= 0 { refresh(reason); continue }
            guard delay.isFinite, delay <= 60 else {
                Log.info("bug", "ignored a refresh \(delay) s away (\(reason))")
                continue
            }
            let due = now + UInt64(delay * 1e9)
            if scheduled.contains(where: { $0 > due ? $0 - due < 15_000_000 : due - $0 < 15_000_000 }) { continue }
            scheduled.insert(due)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.scheduled.remove(due)
                self?.requestList(reason)
            }
        }
    }

    /// Shows at once what is already known (closed, minimised, hidden, focus)
    /// on the last window list, then asks the window server for a new one.
    private func refresh(_ reason: String) {
        Activity.run("apply(\(reason))") { applyList(reason) }
        requestList(reason)
    }

    /// Fetches the window list through `lister` and applies it on main. One fetch
    /// at a time; requests made meanwhile get one more fetch after it, since
    /// the running one may have started before their event.
    private func requestList(_ reason: String) {
        if listInFlight {
            if listPending == nil { listPending = reason }
            return
        }
        listInFlight = true
        let asked = uptimeNs()
        lister.request(.onscreen) { [weak self] reply in
            guard let self else { return }
            self.listInFlight = false
            let took = msSince(asked)
            self.listTimes.add(took)
            if took >= 50 {
                Log.info("slow", "window list took \(ms(took)) (window server \(ms(reply.serverMs))\(reply.viaHelper ? "" : ", in-process")) (\(reason))")
            }
            self.lastList = reply.windows
            self.lastListAt = asked
            if reply.leftOut > 0 {
                Log.debug("list", "left out \(reply.leftOut) windows of a desktop no display shows (a switch in progress)")
            }
            self.noteSpaces(reply.positions)
            self.applyFullScreen(reply.fullScreen)
            Activity.run("refresh(\(reason))") { self.applyList(reason) }
            self.slides = [:]
            self.checkLateRaises(reply.windows)
            if let next = self.listPending {
                self.listPending = nil
                self.requestList(next)
            }
        }
    }

    /// Works out the bar from `lastList` and what AX and the workspace say,
    /// and redraws if anything changed. Main thread; no window server calls.
    private func applyList(_ reason: String) {
        let start = uptimeNs()
        var laps = Laps()
        minute.refreshes += 1
        let all = lastList
        let now = uptimeNs()
        tombstones = tombstones.filter { $0.value > now }
        hiddenApps = hiddenApps.filter { $0.value > now }

        var displays: [(CGDirectDisplayID, CGRect)] = []
        for screen in NSScreen.screens {
            if let id = displayID(of: screen) { displays.append((id, CGDisplayBounds(id))) }
        }

        var shown: [WinInfo] = []
        var unknown: [pid_t: Set<CGWindowID>] = [:]
        var nextCheck: UInt64?
        var onScreen = Set<CGWindowID>()
        for w in all where w.layer == 0 && w.alpha > 0 && w.frame.width >= 80 && w.frame.height >= 60 && w.pid != ownPid {
            guard let app = info(for: w.pid), app.regular else { continue }
            onScreen.insert(w.id)
            if let t = tombstones[w.id], t > now { continue }
            if let h = hiddenApps[w.pid], h > now { continue }
            guard decide(w, now: now, unknown: &unknown, nextCheck: &nextCheck) else { continue }
            let center = CGPoint(x: w.frame.midX, y: w.frame.midY)
            let display = displays.first(where: { $0.1.contains(center) })?.0 ?? CGMainDisplayID()
            shown.append(WinInfo(id: w.id, pid: w.pid, appName: app.name, appKey: app.key, display: display))
        }
        laps.lap("filter")
        for w in shown where showing(w.display) && (!tabTried.contains(w.id) || tabStale.contains(w.id)) {
            guard let bundleID = appInfo[w.pid]?.bundleID, Browsers.chromium[bundleID] != nil else { continue }
            if let r = tabReads[w.pid], r.planned || r.running { continue }   // its result decides
            let tries = tabAttempts[w.id, default: 0]
            guard tries < 3 else {
                // Never matched (not a browser window, DevTools say): the
                // timed read still covers it.
                tabTried.insert(w.id)
                tabStale.remove(w.id)
                continue
            }
            tabAttempts[w.id] = tries + 1
            readTabs(w.pid, bundleID, after: 0.3)   // a new window settles its frame first
        }
        unknownSince = unknownSince.filter { onScreen.contains($0.key) && facts[$0.key] == nil }
        for (pid, ids) in unknown { axWorker.resolve(pid, unknown: ids, reason: "unknown") }
        if let nextCheck {
            // The due time can pass while this runs; an unsigned difference
            // would wrap to ~2^64 and trap in `schedule`.
            let late = uptimeNs()
            schedule("recheck", [nextCheck > late ? Double(nextCheck - late) / 1e9 : 0.001])
        }
        laps.lap("ask")

        updateNeighbours(all)
        laps.lap("notch")

        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var frontID = shown.first(where: { $0.pid == frontPid })?.id
        // AX told us about a focus change the list may not show yet.
        if let h = focusHint, h.pid == frontPid, h.at > lastListAt, shown.contains(where: { $0.id == h.id }) {
            frontID = h.id
        }
        if let o = optimistic {
            if o.until > now { frontID = o.id } else { optimistic = nil }
        }
        laps.lap("front")

        let ordered = order(shown)
        laps.lap("order")
        let head = ordered.map { "\($0.id)@\($0.display)" }.joined(separator: ",") + "|\(frontID ?? 0)|"
        let signature = head + limitsSignature()
        if signature != lastSignature {
            let previous = lastSignature
            render(ordered, front: frontID)
            // Stored with the widths render just measured: a layout squeezed
            // under a narrow limit is stored with that limit, so the limit
            // widening again lays it out again.
            lastSignature = head + limitsSignature()
            laps.lap("render")
            minute.renders += 1
            let took = msSince(start)
            if previous.split(separator: "|").first != signature.split(separator: "|").first {
                Log.debug("render", "\(reason) in \(ms(took)): front #\(frontID ?? 0) [\(ordered.map { "#\($0.id) \($0.appName)" }.joined(separator: ", "))]")
            } else {
                Log.debug("render", "\(reason) in \(ms(took)): front #\(frontID ?? 0)")
            }
            writeState()
            laps.lap("state")
        }
        refreshTimes.add(msSince(start))
        if laps.totalMs >= 20 { Log.info("slow", "applying (\(reason)) took \(ms(laps.totalMs)): \(laps.summary)") }
    }

    /// An island that changes width (Vorssaint showing a timer, say) only
    /// changes the bar when the icons don't fit under its new edge.
    private func limitsSignature() -> String {
        caps.sorted(by: { $0.key < $1.key }).map { cap in
            "\(cap.key):" + ((neededWidth[cap.key] ?? .infinity) <= cap.value ? "fits" : "\(Int(cap.value))")
        }.joined(separator: ",")
    }

    /// Which way each display's desktop moved since the last list, for the
    /// slide in `render`: +1 for a desktop further right in Mission Control.
    private func noteSpaces(_ positions: [String: Int]) {
        guard !positions.isEmpty else { return }
        for display in views.keys {
            guard let key = positions["Main"] != nil ? "Main" : displayUUID[display], let now = positions[key],
                  let before = spacePositions[key], before != now else { continue }
            slides[display] = now > before ? 1 : -1
        }
        spacePositions = positions
    }

    /// Should this on-screen window get an icon?
    private func decide(_ w: CGWin, now: UInt64, unknown: inout [pid_t: Set<CGWindowID>], nextCheck: inout UInt64?) -> Bool {
        guard trusted else { return true }
        if let f = facts[w.id] {
            if f.listed {
                if !f.isDocument && w.frame.width >= 400 && w.frame.height >= 300 && !reportedRejects.contains(w.id) {
                    reportedRejects.insert(w.id)
                    Log.info("filter", "left out a large window #\(w.id) of \(w.owner) (\(Int(w.frame.width))×\(Int(w.frame.height))): subrole \(f.subrole ?? "none")")
                }
                return f.isDocument
            }
            // AX answered without this window: check again at 100, 300 and
            // 800 ms, then whenever the app sends an AX event. AX lists lag a
            // Space switch, so a window last checked before one, or just
            // after, is checked again until a check lands 0.6 s past it.
            let retryAfter: [Double] = [0.1, 0.3, 0.8]
            var due: UInt64?
            if f.checks <= retryAfter.count { due = f.checkedAt + UInt64(retryAfter[f.checks - 1] * 1e9) }
            if spaceChangedAt > 0, f.checkedAt < spaceChangedAt + 600_000_000 {
                let afterSwitch = max(f.checkedAt, spaceChangedAt) + 300_000_000
                due = min(due ?? afterSwitch, afterSwitch)
            }
            if let due {
                if due <= now { unknown[w.pid, default: []].insert(w.id) }
                else { nextCheck = min(nextCheck ?? due, due) }
            }
            // The app answers but lists no windows at all, so AX can't tell
            // them apart: show them (still checking, as the list may have
            // been taken mid Space switch).
            return appFacts[w.pid]?.listsNoWindows == true
        }
        if let a = appFacts[w.pid], a.slowUntil > now { return true }
        if appFacts[w.pid]?.listsNoWindows == true {
            // Shown at once, and asked about once so it gets facts (and the
            // checks above) like any window missing from the list.
            unknown[w.pid, default: []].insert(w.id)
            return true
        }
        if appFacts[w.pid]?.observing != true { observeIfNeeded(w.pid, now: now) }
        // Not classified yet: hold it back for at most 150 ms, then show it.
        let since = unknownSince[w.id] ?? now
        unknownSince[w.id] = since
        unknown[w.pid, default: []].insert(w.id)
        let due = since + 150_000_000
        if due <= now { return true }
        nextCheck = min(nextCheck ?? due, due)
        return false
    }

    private func observeIfNeeded(_ pid: pid_t, now: UInt64) {
        if let asked = observeAsked[pid], now &- asked < 10_000_000_000 { return }
        observeAsked[pid] = now
        axWorker.observe([pid])
    }

    private func info(for pid: pid_t) -> AppInfo? {
        if let i = appInfo[pid], i.regular || msSince(i.checkedAt) < 10_000 { return i }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        let key = app.bundleIdentifier ?? app.executableURL?.path ?? "pid-\(pid)"
        let i = AppInfo(name: app.localizedName ?? key, key: key, regular: app.activationPolicy == .regular,
                        bundleID: app.bundleIdentifier, checkedAt: uptimeNs())
        appInfo[pid] = i
        return i
    }

    private func order(_ windows: [WinInfo]) -> [WinInfo] {
        // Windows first seen together get numbers in creation order.
        for w in windows.sorted(by: { $0.id < $1.id }) where firstSeen[w.id] == nil {
            seenCounter += 1
            firstSeen[w.id] = seenCounter
        }
        var changed = false
        for w in windows where appRank[w.appKey] == nil {
            appRank[w.appKey] = appOrder.count
            appOrder.append(w.appKey)
            changed = true
        }
        if changed {
            if appOrder.count > 300 { appOrder.removeFirst(appOrder.count - 300); appRank = [:]; for (i, k) in appOrder.enumerated() { appRank[k] = i } }
            UserDefaults.standard.set(appOrder, forKey: "appOrder")
        }
        return windows.sorted { a, b in
            let ra = appRank[a.appKey] ?? .max, rb = appRank[b.appKey] ?? .max
            if ra != rb { return ra < rb }
            if a.pid != b.pid { return a.pid < b.pid }
            return (firstSeen[a.id] ?? 0) < (firstSeen[b.id] ?? 0)
        }
    }

    // MARK: - The notch

    private func updateNeighbours(_ all: [CGWin]) {
        var found: [Neighbour] = []
        let now = uptimeNs()
        for (display, panel) in panels {
            let strip = cgRect(fromAppKit: panel.frame)
            let near = Notch.neighbours(in: all, strip: strip, level: panel.level.rawValue, ownPid: ownPid)
            found += near
            // Keep the last closed-island cap while the island is expanded.
            if near.contains(where: \.closed) || near.isEmpty {
                caps[display] = Notch.iconLimit(strip: strip, neighbours: near)
            }
            // Stay under same-level neighbours; at most one repair every 2 s.
            for (what, p) in [("strip", panel), ("cover", covers[display])] {
                guard let p, now &- lastRepair > 2_000_000_000, p.isVisible else { continue }
                let ours = CGWindowID(p.windowNumber)
                if let ourIndex = all.firstIndex(where: { $0.id == ours }),
                   let island = near.first(where: { n in n.win.layer == p.level.rawValue
                       && (all.firstIndex(where: { $0.id == n.win.id }) ?? 0) > ourIndex }) {
                    p.order(.below, relativeTo: Int(island.win.id))
                    lastRepair = now
                    repairs += 1
                    Log.info("notch", "moved the \(what) below \(island.win.owner) #\(island.win.id)")
                }
            }
        }
        let before = Notch.describe(neighbours), after = Notch.describe(found)
        if before != after {
            Log.info("notch", "neighbours: \(after.isEmpty ? "none" : after); icon limit \(caps.map { "\($0.key): \(Int($0.value))" }.joined(separator: ", "))")
        }
        neighbours = found
    }

    // MARK: - Panels and drawing

    private func buildPanels() {
        tooltip.hide()
        panels.values.forEach { $0.orderOut(nil) }
        covers.values.forEach { $0.orderOut(nil) }
        panels = [:]
        views = [:]
        covers = [:]
        coverArea = [:]
        // Measured on the old arrangement: a display that moved would get a
        // cover sized from another position.
        menuEnd = [:]
        menuOwner = nil
        hiddenForFullScreen = []
        for screen in NSScreen.screens {
            let height = screen.safeAreaInsets.top
            guard height > 0, let id = displayID(of: screen) else { continue }
            let width = screen.auxiliaryTopLeftArea?.width ?? (screen.frame.width / 2 - 90)
            let frame = NSRect(x: screen.frame.minX, y: screen.frame.maxY - height, width: width, height: height)
            let panel = blackPanel(frame)
            panel.acceptsMouseMovedEvents = true
            let view = StripView(frame: NSRect(origin: .zero, size: frame.size), display: id)
            view.delegate = self
            panel.contentView = view
            panel.setFrame(frame, display: false)
            panels[id] = panel
            views[id] = view
            Log.info("panel", "display \(id): strip \(cgRect(fromAppKit: frame)) at level \(stripLevel.rawValue), \(orderIn(panel, display: id))")
            if let right = screen.auxiliaryTopRightArea {
                let area = NSRect(x: screen.frame.maxX - right.width, y: frame.minY, width: right.width, height: height)
                let cover = blackPanel(NSRect(x: area.minX, y: area.minY, width: 1, height: area.height))
                cover.contentView = NSView()
                covers[id] = cover
                coverArea[id] = area
            }
            if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
                displayUUID[id] = CFUUIDCreateString(nil, uuid) as String
            }
        }
        lastSignature = ""
        updateCovers()
        checkMenuBar()
    }

    /// A borderless black panel on the strip's level, on every Space.
    private func blackPanel(_ frame: NSRect) -> StripPanel {
        let panel = StripPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = stripLevel
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        // Without .fullScreenAuxiliary, but a panel at this level still
        // shows on full-screen Spaces: `applyFullScreen` takes it off.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return panel
    }

    /// Puts a strip or cover on screen under a notch island that is already
    /// there (at the same level, found from the display's strip), otherwise
    /// on top of its level.
    private func orderIn(_ panel: StripPanel, display: CGDirectDisplayID) -> String {
        let strip = cgRect(fromAppKit: panels[display]?.frame ?? panel.frame)
        if let island = Notch.neighbours(in: lastList, strip: strip, level: stripLevel.rawValue, ownPid: ownPid)
            .first(where: { $0.win.layer == stripLevel.rawValue }) {
            panel.order(.below, relativeTo: Int(island.win.id))
            return "under \(island.win.owner) #\(island.win.id)"
        }
        panel.orderFrontRegardless()
        return "on top"
    }

    /// A full-screen app gets the whole screen: the strip leaves a display
    /// while it shows a full-screen app's Space, and comes back with the
    /// desktop. Each window list says which displays those are.
    private func applyFullScreen(_ fullScreen: Set<String>) {
        for (display, panel) in panels {
            let hide = fullScreen.contains("Main") || displayUUID[display].map { fullScreen.contains($0) } == true
            guard hide != hiddenForFullScreen.contains(display) else { continue }
            if hide {
                hiddenForFullScreen.insert(display)
                panel.orderOut(nil)
                if let id = tooltip.windowID, views[display]?.slots.contains(where: { $0.info.id == id }) == true {
                    hoveredID = nil
                    hideTooltip(now: true)
                }
                Log.info("panel", "display \(display): hidden, a full-screen app is showing")
            } else {
                hiddenForFullScreen.remove(display)
                Log.info("panel", "display \(display): back, \(orderIn(panel, display: display))")
            }
            updateCovers()
            writeState()
        }
    }

    // MARK: - Menus right of the notch

    /// Asks where the frontmost app's menus end. When they spill right of
    /// the notch, a cover hides them up to there. When a newly front app's
    /// menus can't be read (it isn't answering yet, or its menu bar is on a
    /// display without a cover), the cover goes off rather than keep another
    /// app's width. An accessory app has no menus of its own: the menu bar
    /// keeps the last app's, so the cover stays.
    private func checkMenuBar() {
        guard !covers.isEmpty, let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular, app.processIdentifier != ownPid else { return }
        let pid = app.processIdentifier
        axWorker.lastMenuFrame(of: pid) { [weak self] frame in
            guard let self, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            var ends = self.menuOwner == pid ? self.menuEnd : [:]
            var note = "pid \(pid): menus not readable yet, cover off"
            if let frame, let display = self.covers.keys.first(where: { CGDisplayBounds($0).contains(CGPoint(x: frame.midX, y: frame.midY)) }) {
                ends[display] = frame.maxX
                self.menuOwner = pid
                note = "pid \(pid): menus end at x \(Int(frame.maxX)) on display \(display)"
            }
            guard ends != self.menuEnd else { return }
            self.menuEnd = ends
            Log.debug("cover", note)
            self.updateCovers()
        }
    }

    private func updateCovers() {
        for (display, cover) in covers {
            guard let area = coverArea[display] else { continue }
            let width = min(area.width, max(0, (menuEnd[display] ?? 0) + 6 - area.minX))
            if width < 1 || hiddenForFullScreen.contains(display) {
                if cover.isVisible {
                    cover.orderOut(nil)
                    Log.info("cover", "display \(display): off")
                }
                continue
            }
            let frame = NSRect(x: area.minX, y: area.minY, width: width, height: area.height)
            if cover.frame != frame { cover.setFrame(frame, display: true) }
            if !cover.isVisible {
                let how = orderIn(cover, display: display)
                Log.info("cover", "display \(display): covering the menus right of the notch, x \(Int(area.minX))…\(Int(area.minX + width)), \(how)")
            }
        }
    }

    private func render(_ ordered: [WinInfo], front: CGWindowID?) {
        for (display, view) in views {
            let windows = ordered.filter { $0.display == display }
            let limit = caps[display] ?? view.bounds.width
            let groups = max(0, Set(windows.map(\.pid)).count - 1)
            var sets = windows.map { iconSet(for: $0) }
            let needed = leadingInset + sets.reduce(0) { $0 + tabSlotWidth($1.icons.count) } + CGFloat(groups) * groupGap
            neededWidth[display] = needed
            var slot = slotWidth
            if needed > limit, !windows.isEmpty {
                // Too many: browser windows keep only their first site icon,
                // then every slot narrows.
                sets = sets.map { ($0.tabs ? Array($0.icons.prefix(1)) : $0.icons, $0.tabs, $0.key + "/1") }
                if leadingInset + CGFloat(windows.count) * slotWidth + CGFloat(groups) * groupGap > limit {
                    slot = max(minSlotWidth, (limit - leadingInset - CGFloat(groups) * groupGap) / CGFloat(windows.count))
                }
            }
            var x = leadingInset
            var previous: pid_t?
            var slots: [Slot] = []
            for (w, set) in zip(windows, sets) {
                if let p = previous, p != w.pid { x += groupGap }
                let width = set.icons.count > 1 ? tabSlotWidth(set.icons.count) : slot
                if x + width > limit + 0.5 {
                    Log.info("render", "display \(display): \(windows.count - slots.count) icons don't fit and are left out")
                    break
                }
                slots.append(Slot(info: w, frame: NSRect(x: x, y: 0, width: width, height: view.bounds.height),
                                  icons: set.icons, tabs: set.tabs, iconKey: set.key))
                x += width
                previous = w.pid
            }
            if view.update(slots: slots, front: front, slide: slides[display] ?? 0) {
                Log.debug("render", "display \(display): desktop switch, icons slide \(slides[display] == 1 ? "left" : "right")")
            }
        }
        if let id = hoveredID, !ordered.contains(where: { $0.id == id }) { hideTooltip(now: true) }
    }

    /// A browser window's site icons when known, else its app's icon.
    private func iconSet(for w: WinInfo) -> (icons: [NSImage], tabs: Bool, key: String) {
        if let tabs = tabIcons[w.id], !tabs.isEmpty {
            return (tabs.map { $0?.image ?? icon(for: w) }, true, "tabs:" + tabs.map { "\($0?.id ?? 0)" }.joined(separator: ","))
        }
        return ([icon(for: w)], false, "app")
    }

    private func icon(for w: WinInfo) -> NSImage {
        if let cached = icons[w.appKey] { return cached }
        let own = NSRunningApplication(processIdentifier: w.pid)?.icon
        let source = own ?? NSImage(named: NSImage.applicationIconName)!
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(iconSize * 2), pixelsHigh: Int(iconSize * 2),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = NSSize(width: iconSize, height: iconSize)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(in: NSRect(x: 0, y: 0, width: iconSize, height: iconSize))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        if own != nil { icons[w.appKey] = image }   // else ask again next time
        return image
    }

    // MARK: - Browser tabs

    /// A window title changed: the tab matching compares titles, and for a
    /// browser the tabs may have changed too.
    private func titleChanged(_ pid: pid_t, window: CGWindowID, title: String?) {
        if facts[window] != nil { facts[window]?.title = title }
        guard let bundleID = appInfo[pid]?.bundleID, Browsers.chromium[bundleID] != nil else { return }
        let onStrip: (Slot) -> Bool = window != 0 ? { $0.info.id == window } : { $0.info.pid == pid }
        guard views.contains(where: { showing($0.key) && $0.value.slots.contains(where: onStrip) }) else {
            // On another Space, minimised, or on a strip that isn't showing:
            // read when it shows up.
            if window != 0 { tabStale.insert(window); tabAttempts[window] = nil }
            return
        }
        // A page whose title ticks (a timer, a call's length) would mean a
        // read every half second: after three reads in a row that changed
        // nothing, one every 15 s will do until one changes something.
        if let r = tabReads[pid], r.unchanged >= 3, msSince(r.last) < 15_000 { return }
        readTabs(pid, bundleID)
    }

    /// A strip that is on screen; tab reads for anything else wait.
    private func showing(_ display: CGDirectDisplayID) -> Bool {
        pollTimer != nil && views[display] != nil && !hiddenForFullScreen.contains(display)
    }

    /// Tabs can change without a title change (a background tab loads), so
    /// browsers with windows on the bar are read again every 16 s.
    private func readShownBrowsers() {
        let pids = Set(views.filter { showing($0.key) }.values.flatMap { $0.slots.map(\.info.pid) })
        for pid in pids where msSince(tabReads[pid]?.last ?? 0) >= 15_000 {
            if let bundleID = appInfo[pid]?.bundleID, Browsers.chromium[bundleID] != nil { readTabs(pid, bundleID, after: 0) }
        }
    }

    /// Reads a browser's tabs `after` seconds from now: at most every 0.5 s,
    /// one read at a time, and changes during a read get one more after it.
    private func readTabs(_ pid: pid_t, _ bundleID: String, after delay: Double = 0.15) {
        var r = tabReads[pid] ?? TabReads()
        if r.running { r.again = true; tabReads[pid] = r; return }
        guard !r.planned else { return }
        r.planned = true
        tabReads[pid] = r
        let wait = max(delay, 0.5 - msSince(r.last) / 1000)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, var r = self.tabReads[pid] else { return }
            r.planned = false
            r.running = true
            r.last = uptimeNs()
            self.tabReads[pid] = r
            self.tabReader.read(pid: pid, bundleID: bundleID) { [weak self] result in
                guard let self, var r = self.tabReads[pid] else { return }
                r.running = false
                let again = r.again
                r.again = false
                self.tabReads[pid] = r
                switch result {
                case .windows(let windows):
                    let changed = self.applyTabs(windows, pid: pid)
                    self.tabReads[pid]?.unchanged = changed > 0 ? 0 : r.unchanged + 1
                case .denied: self.dropTabIcons(of: pid)
                case .failed: break
                }
                if again { self.readTabs(pid, bundleID, after: 0) }
            }
        }
    }

    /// Matches the browser's windows to its windows on screen by frame (the
    /// title breaks a tie) and keeps each one's icons.
    @discardableResult
    private func applyTabs(_ windows: [(window: BrowserWindow, icons: TabIcons)], pid: pid_t) -> Int {
        let open = windows.filter { !$0.window.minimized }
        func near(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) <= 2 && abs(a.minY - b.minY) <= 2 && abs(a.width - b.width) <= 2 && abs(a.height - b.height) <= 2
        }
        var matched = 0, changed = 0
        for cg in lastList where cg.pid == pid && cg.layer == 0 {
            var matches = open.filter { near($0.window.bounds, cg.frame) }
            if matches.count > 1, let title = facts[cg.id]?.title { matches = matches.filter { $0.window.name == title } }
            guard matches.count == 1 else { continue }
            matched += 1
            tabTried.insert(cg.id)
            tabStale.remove(cg.id)
            tabAttempts[cg.id] = nil
            let icons = matches[0].icons
            if tabIcons[cg.id].map({ $0.map { $0?.id } }) != icons.map({ $0?.id }) {
                tabIcons[cg.id] = icons
                changed += 1
            }
        }
        Log.debug("tabs", "pid \(pid): \(matched) windows on screen matched, \(changed) changed")
        if changed > 0 {
            lastSignature = ""
            Activity.run("apply(tabs)") { applyList("tabs") }
        }
        return changed
    }

    /// Reading tabs was turned off: back to the app icon.
    private func dropTabIcons(of pid: pid_t) {
        let ids = Set(lastList.filter { $0.pid == pid }.map(\.id))
        guard tabIcons.keys.contains(where: ids.contains) else { return }
        tabIcons = tabIcons.filter { !ids.contains($0.key) }
        lastSignature = ""
        Activity.run("apply(tabs)") { applyList("tabs") }
    }

    // MARK: - Hover and tooltip

    func hoverChanged(to slot: Slot?, in view: StripView) {
        guard let slot else {
            hoveredID = nil
            hideTooltip(now: false)
            return
        }
        hideWork?.cancel()
        hoveredID = slot.info.id
        minute.hovers += 1
        let start = uptimeNs()
        showTooltip(slot, in: view, title: facts[slot.info.id]?.title)
        Log.debug("hover", "#\(slot.info.id) \(slot.info.appName) tooltip in \(ms(msSince(start)))")
        let cached = facts[slot.info.id]?.title
        axWorker.title(of: slot.info.id, pid: slot.info.pid) { [weak self, weak view] title in
            guard let self, let view, self.hoveredID == slot.info.id, title != cached else { return }
            self.facts[slot.info.id]?.title = title
            self.showTooltip(slot, in: view, title: title)
        }
    }

    private func showTooltip(_ slot: Slot, in view: StripView, title: String?) {
        guard let window = view.window else { return }
        let anchor = window.convertToScreen(view.convert(slot.frame, to: nil))
        let name = slot.info.appName
        let text = (title ?? "").isEmpty || title == name ? name : "\(name) · \(title!)"
        tooltip.show(text, for: slot.info.id, below: anchor)
        writeState()
    }

    private func hideTooltip(now: Bool) {
        hideWork?.cancel()
        if now {
            tooltip.hide()
            writeState()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hoveredID == nil else { return }
            self.tooltip.hide()
            self.writeState()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    // MARK: - Clicks

    func clicked(_ slot: Slot, in view: StripView) {
        let w = slot.info
        let start = uptimeNs()
        minute.clicks += 1
        optimistic = (w.id, start + 900_000_000)
        views.values.forEach { $0.setFront(w.id) }
        lastRaise = ["windowId": Int(w.id), "requestedAtUptimeNs": start, "result": "pending", "ms": 0.0]
        writeState()
        guard trusted else {
            NSRunningApplication(processIdentifier: w.pid)?.activate(options: [])
            promptForAccessibility()
            Log.info("raise", "#\(w.id) \(w.appName): no Accessibility, asked the app to activate")
            // If the app ignores that, the highlight must not stay on this icon.
            lastSignature = ""
            schedule("click", [0.95])
            return
        }
        clickSeq += 1
        let seq = clickSeq
        latestClick = (w, start, seq)
        axWorker.raise(w.id, pid: w.pid) { [weak self] outcome in
            guard let self else { return }
            guard let outcome else {
                Log.info("raise", "#\(w.id) \(w.appName): skipped, a newer raise was asked for before it started")
                return
            }
            Log.info("raise", "#\(w.id) \(w.appName): \(outcome.summary)")
            self.watchIfLate(w, seq: seq, outcome: outcome)
            guard seq == self.clickSeq else { return }
            self.verifyRaise(w, start: start, attempt: 1, seq: seq)
        }
    }

    /// A raise can put its window in front after a newer click: when its app
    /// answered only after that click came, or when the app didn't answer in
    /// time and may still carry the raise out when it wakes up. Such raises
    /// are watched (for 1 s, or 10 s when the app may still act on it); if
    /// the window comes in front of the newest click's window, that one is
    /// raised again, once.
    private func watchIfLate(_ w: WinInfo, seq: Int, outcome: RaiseOutcome) {
        guard seq != clickSeq || outcome.mayLandLate else { return }
        lateRaises[w.pid] = (w, seq, uptimeNs() + (outcome.mayLandLate ? 10_000_000_000 : 1_000_000_000))
        schedule("late raise", outcome.mayLandLate ? [0.06, 0.3, 0.7, 1.5, 3, 6] : [0.06])
    }

    /// Runs on every fresh window list while a raise is watched.
    private func checkLateRaises(_ list: [CGWin]) {
        guard !lateRaises.isEmpty else { return }
        let now = uptimeNs()
        lateRaises = lateRaises.filter { $0.value.until > now }
        guard let latest = latestClick, latest.seq == clickSeq else { lateRaises = [:]; return }
        // A click anywhere or a modifier key (Cmd-Tab) since the newest click
        // may be what brought the other window forward: leave it to the user.
        if actedSince(latest.start) {
            if !lateRaises.isEmpty { Log.debug("raise", "stopped watching late raises: input since the last click") }
            lateRaises = [:]
            return
        }
        let front = frontWindow(on: latest.w.display, in: list, target: latest.w)
        for (pid, late) in lateRaises where late.seq < latest.seq && late.w.id != latest.w.id {
            let covered = pid == latest.w.pid ? front?.id == late.w.id : front?.pid == pid
            guard covered else { continue }
            lateRaises[pid] = nil
            Log.info("raise", "#\(late.w.id) \(late.w.appName) came to the front after the newer click on #\(latest.w.id); raising #\(latest.w.id) again")
            retryRaise(latest.w, start: latest.start, seq: latest.seq)
            return
        }
    }

    /// Did the user click, or press a modifier key, after `start`?
    private func actedSince(_ start: UInt64) -> Bool {
        let elapsed = msSince(start) / 1000
        let types: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .flagsChanged]
        return types.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < elapsed - 0.02 }
    }

    private func verifyRaise(_ w: WinInfo, start: UInt64, attempt: Int, seq: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.lister.request(.onscreen) { reply in
                self?.checkRaise(w, reply.windows, start: start, attempt: attempt, seq: seq)
            }
        }
    }

    private func checkRaise(_ w: WinInfo, _ list: [CGWin], start: UInt64, attempt: Int, seq: Int) {
        // A newer click owns the front now: checking or retrying this one
        // would pull its window back over the one clicked since.
        guard seq == clickSeq else {
            Log.info("raise", "#\(w.id) \(w.appName): a newer click came within \(ms(msSince(start))); not checked")
            return
        }
        let (ok, front) = isFront(w, in: list)
        if ok {
            finishRaise(w, start: start, result: "ok", note: attempt > 1 ? "after a retry" : "")
        } else if attempt == 1 {
            Log.info("raise", "#\(w.id) not in front after \(ms(msSince(start))) (front is \(front)); trying again")
            retryRaise(w, start: start, seq: seq)
        } else {
            if failedSeq != seq { failedSeq = seq; minute.raiseFails += 1 }
            finishRaise(w, start: start, result: "fail", note: "front is \(front)")
        }
    }

    private func retryRaise(_ w: WinInfo, start: UInt64, seq: Int) {
        axWorker.raise(w.id, pid: w.pid) { [weak self] outcome in
            guard let self, let outcome else { return }
            Log.info("raise", "#\(w.id) retry: \(outcome.summary)")
            self.watchIfLate(w, seq: seq, outcome: outcome)
            guard seq == self.clickSeq else { return }
            self.verifyRaise(w, start: start, attempt: 2, seq: seq)
        }
    }

    private func finishRaise(_ w: WinInfo, start: UInt64, result: String, note: String) {
        let took = msSince(start)
        Log.info("raise", "#\(w.id) \(w.appName): \(result) in \(ms(took)) \(note)")
        lastRaise["result"] = result
        lastRaise["ms"] = took
        if optimistic?.id == w.id { optimistic = nil }
        lastSignature = ""
        refresh("raise")
        writeState()
    }

    /// The front app window on `display` in `list`. The target app's other
    /// windows that aren't known document windows (its sheets, for one) are
    /// passed over, so a window with a sheet open counts as in front; the
    /// target itself never is, whatever AX says about it.
    private func frontWindow(on display: CGDirectDisplayID, in list: [CGWin], target: WinInfo) -> CGWin? {
        let displays: [(CGDirectDisplayID, CGRect)] = NSScreen.screens.compactMap { s in displayID(of: s).map { ($0, CGDisplayBounds($0)) } }
        return list.first { c in
            guard c.layer == 0, c.alpha > 0, c.frame.width >= 80, c.frame.height >= 60, c.pid != ownPid,
                  info(for: c.pid)?.regular == true else { return false }
            if c.pid == target.pid, c.id != target.id, facts[c.id]?.isDocument != true { return false }
            let center = CGPoint(x: c.frame.midX, y: c.frame.midY)
            return (displays.first(where: { $0.1.contains(center) })?.0 ?? CGMainDisplayID()) == display
        }
    }

    /// Is `w` the front window on its display in `list`, and its app the active one?
    private func isFront(_ w: WinInfo, in list: [CGWin]) -> (Bool, String) {
        let first = frontWindow(on: w.display, in: list, target: w)
        let active = NSWorkspace.shared.frontmostApplication?.processIdentifier == w.pid
        return (first?.id == w.id && active, "#\(first?.id ?? 0) \(first?.owner ?? "none"), active app pid \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
    }

    // MARK: - State file and snapshots

    private func writeState() {
        stateSeq += 1
        var panelList: [[String: Any]] = []
        for (display, view) in views {
            guard let panel = panels[display] else { continue }
            let buttons: [[String: Any]] = view.slots.map { slot in
                let screen = panel.convertToScreen(view.convert(slot.frame, to: nil))
                return ["windowId": Int(slot.info.id), "pid": Int(slot.info.pid), "app": slot.info.appName,
                        "tabIcons": slot.tabs ? slot.icons.count : 0,
                        "front": slot.info.id == view.frontID, "hovered": slot.info.id == view.hoveredID,
                        "frame": json(cgRect(fromAppKit: screen))]
            }
            panelList.append(["display": Int(display), "windowNumber": panel.windowNumber, "level": panel.level.rawValue,
                              "hiddenForFullScreen": hiddenForFullScreen.contains(display),
                              "frame": json(cgRect(fromAppKit: panel.frame)),
                              "iconAreaMaxX": Double(caps[display] ?? panel.frame.width), "buttons": buttons])
        }
        var tip: [String: Any] = ["visible": tooltip.isVisible, "chars": tooltip.text.count]
        if tooltip.isVisible, let id = tooltip.windowID {
            tip["windowId"] = Int(id)
            let pid = views.values.flatMap(\.slots).first(where: { $0.info.id == id })?.info.pid
            if let pid, appInfo[pid]?.bundleID == testAppBundleID { tip["text"] = tooltip.text }
        }
        StateFile.write([
            "version": 2, "engine": "events", "seq": stateSeq, "pid": Int(ownPid),
            "writtenAtUptimeNs": uptimeNs(), "trusted": trusted, "windowServerRaise": Raiser.hasWindowServerCalls,
            "panels": panelList, "tooltip": tip,
            "neighbours": neighbours.map { ["windowId": Int($0.win.id), "owner": $0.win.owner, "pid": Int($0.win.pid),
                                            "layer": $0.win.layer, "frame": json($0.win.frame), "closed": $0.closed] as [String: Any] },
            "lastRaise": lastRaise, "recentRefreshMs": refreshTimes.values,
            "stalls": stalls.recent.map { ["atUptimeNs": $0.at, "ms": $0.ms] as [String: Any] },
        ])
    }

    /// Draws the live bar (and the tooltip, if shown) into PNGs next to the
    /// state file, then posts dev.windowstrip.snapshot.done. Only with
    /// `defaults write dev.windowstrip snapshots -bool true`, read at launch.
    @objc private func snapshotRequested() {
        let dir = StateFile.url.deletingLastPathComponent()
        for (display, view) in views {
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("snapshot-\(display).png"))
        }
        let tipURL = dir.appendingPathComponent("snapshot-tooltip.png")
        if let rep = tooltip.snapshot() {
            try? rep.representation(using: .png, properties: [:])?.write(to: tipURL)
        } else {
            try? FileManager.default.removeItem(at: tipURL)
        }
        Log.debug("state", "snapshot written")
        DistributedNotificationCenter.default().postNotificationName(Notification.Name("dev.windowstrip.snapshot.done"),
                                                                     object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func screenSummary() -> String {
        NSScreen.screens.map { "\($0.localizedName) \(Int($0.frame.width))×\(Int($0.frame.height)) notch=\($0.safeAreaInsets.top > 0)" }
            .joined(separator: "; ")
    }
}
