// Everything that talks to other apps over Accessibility (AX) happens here,
// off the main thread, so a slow or hung app can never freeze the bar.
//
// Three lanes:
// - an observer thread whose run loop receives AXObserver callbacks
//   (one observer per regular app);
// - a serial query queue that asks apps about their windows (subrole, title)
//   and owns all the facts learned so far;
// - one serial action queue per app for raises and title reads, so a click
//   never waits behind a slow query, and an app that stops answering only
//   holds up actions aimed at itself.
//
// Facts about a window, once learned, are kept until the window no longer
// exists anywhere (AX only lists windows on the current Space, so forgetting
// on a Space switch would mean asking again every time).

import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

/// What AX says about one window.
struct WindowFacts {
    let pid: pid_t
    /// False when the app answered but didn't list this window (an overlay or
    /// helper window, or one AX hadn't caught up with yet).
    var listed: Bool
    var subrole: String?
    var title: String?
    var checkedAt: UInt64
    var checks: Int

    var isDocument: Bool {
        listed && (subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String))
    }
}

/// What AX says about one app.
struct AppFacts {
    var observing = false
    /// The app answers but lists no windows at all, so AX can't tell its
    /// windows apart; the bar then shows all of them.
    var listsNoWindows = false
    /// The app stopped answering; its windows are shown and it isn't asked
    /// again until then.
    var slowUntil: UInt64 = 0
}

/// Window events applied straight to the bar, before the window server's
/// list catches up (a closing window stays on screen for its animation).
enum AXEvent {
    case closed(CGWindowID)
    case minimized(CGWindowID)
    case restored(CGWindowID)
    case hidden(pid_t)
    case shown(pid_t)
    case created(CGWindowID, pid_t)
    /// Focused or main window changed; the window when AX named one.
    case focused(CGWindowID?, pid_t)
}

/// What a raise did, for the log, and whether the app may still carry it
/// out later: it didn't answer in time, or wasn't asked over AX because it
/// had stopped answering, and a busy app still acts on queued messages and
/// make-key events when it wakes up.
struct RaiseOutcome {
    let summary: String
    let mayLandLate: Bool
}

struct AXUpdate {
    let facts: [CGWindowID: WindowFacts]
    let apps: [pid_t: AppFacts]
    let event: AXEvent?
    let reason: String
}

private let appLevelNotifications = [
    kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
    kAXApplicationHiddenNotification, kAXApplicationShownNotification,
]
private let windowLevelNotifications = [
    kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
    kAXWindowDeminiaturizedNotification, kAXTitleChangedNotification,
]

/// The single worker; the C callback below needs to find it.
let axWorker = AXWorker()

/// refcon is 0 for app-level notifications and the window id for
/// window-level ones (the element of a closed window can't tell its id).
private let observerCallback: AXObserverCallback = { _, element, notification, refcon in
    let windowID = CGWindowID(truncatingIfNeeded: Int(bitPattern: refcon))
    axWorker.received(notification as String, element, windowID)
}

final class AXWorker {
    /// Called on the main thread.
    var onUpdate: ((AXUpdate) -> Void)?
    /// Called on the main thread with the pid of an app whose window title
    /// changed (for browsers: the tabs may have changed). Set before `start`.
    /// A window's title changed: its pid, id and new title, on main.
    var onTitleChange: ((pid_t, CGWindowID, String?) -> Void)?

    /// Default timeout for every AX message this process sends.
    static let queryTimeout: Float = 0.5

    private var observerRunLoop: CFRunLoop!
    private let queries = DispatchQueue(label: "dev.windowstrip.ax.query", qos: .userInitiated)

    // Action lanes, guarded by laneLock.
    private let laneLock = NSLock()
    private var lanes: [pid_t: DispatchQueue] = [:]
    /// Apps whose last action timed out get no AX messages until then: a
    /// message to a hung app is still carried out when it wakes up, so a raise
    /// sent then would jump in front of whatever was clicked since.
    private var unresponsiveUntil: [pid_t: UInt64] = [:]
    private var latestRaise = 0
    private var latestTitle = 0

    // Owned by the query queue.
    private var facts: [CGWindowID: WindowFacts] = [:]
    private var apps: [pid_t: AppFacts] = [:]
    private var observers: [pid_t: AXObserver] = [:]
    private var watched = Set<CGWindowID>()
    private var lastResolve: [pid_t: UInt64] = [:]
    private var backoff: [pid_t: Double] = [:]
    private var registerAttempts: [pid_t: Int] = [:]
    private var stats = (resolves: 0, resolveMax: 0.0, timeouts: 0, notifications: 0, titles: 0)

    // Shared with the action queue.
    private let elementLock = NSLock()
    private var elements: [CGWindowID: AXUIElement] = [:]

    func start() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [unowned self] in
            self.observerRunLoop = CFRunLoopGetCurrent()
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "dev.windowstrip.ax.observers"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXWorker.queryTimeout)
    }

    // MARK: - Requests from the main thread

    func observe(_ pids: [pid_t]) {
        queries.async { for pid in pids { self.register(pid) } }
    }

    func forget(_ pid: pid_t) {
        laneLock.lock()
        lanes[pid] = nil
        unresponsiveUntil[pid] = nil
        laneLock.unlock()
        queries.async {
            if let observer = self.observers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(self.observerRunLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            self.apps[pid] = nil
            self.lastResolve[pid] = nil
            self.backoff[pid] = nil
            self.registerAttempts[pid] = nil
            self.waiting[pid] = nil
            let ids = self.facts.filter { $0.value.pid == pid }.map(\.key)
            for id in ids { self.drop(id) }
            self.publish(nil, "terminated")
        }
    }

    /// Drops facts for windows that no longer exist anywhere, and what is
    /// kept per app for apps that quit (a late block can bring it back after
    /// `forget`). Facts learned after `asked`, when `existing` was listed,
    /// are kept: their window may be newer than the list.
    func prune(keeping existing: Set<CGWindowID>, listedAt asked: UInt64) {
        laneLock.lock()
        lanes = lanes.filter { isRunning($0.key) }
        unresponsiveUntil = unresponsiveUntil.filter { isRunning($0.key) }
        laneLock.unlock()
        queries.async {
            let gone = self.facts.filter { !existing.contains($0.key) && $0.value.checkedAt < asked }.map(\.key)
            for id in gone { self.drop(id) }
            if !gone.isEmpty { Log.debug("ax", "forgot \(gone.count) windows that no longer exist") }
            self.apps = self.apps.filter { isRunning($0.key) }
            self.lastResolve = self.lastResolve.filter { isRunning($0.key) }
            self.backoff = self.backoff.filter { isRunning($0.key) }
            self.registerAttempts = self.registerAttempts.filter { isRunning($0.key) }
            self.waiting = self.waiting.filter { isRunning($0.key) }
        }
    }

    /// Starts over: after Accessibility is granted again, observers set up
    /// before may be dead, and failures seen while it was off are stale.
    func reset() {
        laneLock.lock()
        unresponsiveUntil = [:]
        laneLock.unlock()
        queries.async {
            for observer in self.observers.values {
                CFRunLoopRemoveSource(self.observerRunLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            self.observers = [:]
            self.apps = [:]
            self.facts = [:]
            self.watched = []
            self.lastResolve = [:]
            self.backoff = [:]
            self.registerAttempts = [:]
            self.waiting = [:]
            self.elementLock.lock()
            self.elements = [:]
            self.elementLock.unlock()
            Log.info("ax", "starting over: forgot every app and window")
            self.publish(nil, "reset")
        }
    }

    /// Learns about the windows of `pid`, including the on-screen `unknown`
    /// ones the main thread has no facts for.
    func resolve(_ pid: pid_t, unknown: Set<CGWindowID>, reason: String) {
        queries.async {
            if let app = self.apps[pid], app.slowUntil > uptimeNs() { return }
            self.waiting[pid, default: []].formUnion(unknown)
            if let last = self.lastResolve[pid], msSince(last) < 50 {
                // Asked again within 50 ms: answer once, a moment later.
                guard !self.deferred.contains(pid) else { return }
                self.deferred.insert(pid)
                self.queries.asyncAfter(deadline: .now() + 0.06) {
                    self.deferred.remove(pid)
                    self.resolveWaiting(pid, reason: reason)
                }
                return
            }
            self.resolveWaiting(pid, reason: reason)
        }
    }

    private var waiting: [pid_t: Set<CGWindowID>] = [:]
    private var deferred = Set<pid_t>()
    /// Apps with a registration retry already planned.
    private var registerRetry = Set<pid_t>()

    private func resolveWaiting(_ pid: pid_t, reason: String) {
        let unknown = waiting.removeValue(forKey: pid) ?? []
        guard isRunning(pid) else { return }
        resolveNow(pid, unknown: unknown, reason: reason)
        publish(nil, "resolved:\(reason)")
    }

    /// Reads one window's current title and calls back on main, only when the
    /// read worked. Dropped when a newer title read was asked for before this
    /// one started (the pointer moved on).
    func title(of id: CGWindowID, pid: pid_t, _ done: @escaping (String?) -> Void) {
        let token = nextToken(\.latestTitle)
        lane(pid).async {
            guard self.isLatest(token, \.latestTitle), self.answering(pid) else { return }
            let start = uptimeNs()
            guard let element = self.element(id, pid) else { return }
            var value: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
            Log.debug("ax", "title #\(id) read in \(ms(msSince(start))) (\(err.rawValue))")
            if err == .cannotComplete { self.noteTimeout(pid, "a title read") }
            guard err == .success else { return }
            let title = value as? String
            DispatchQueue.main.async { done(title) }
        }
    }

    /// Brings exactly one window to the front and makes it key. `done` gets
    /// nil when a newer raise was asked for before this one started.
    func raise(_ id: CGWindowID, pid: pid_t, _ done: @escaping (RaiseOutcome?) -> Void) {
        let token = nextToken(\.latestRaise)
        lane(pid).async {
            guard self.isLatest(token, \.latestRaise) else { DispatchQueue.main.async { done(nil) }; return }
            let start = uptimeNs()
            let answering = self.answering(pid)
            let element = answering ? self.element(id, pid) : nil
            let result = Raiser.raise(window: id, pid: pid, element: element, useAX: answering)
            if result.axTimedOut { self.noteTimeout(pid, "a raise") }
            let summary = "\(result.steps)\(answering ? "" : " (app not answering, window server only)") in \(ms(msSince(start)))"
            let outcome = RaiseOutcome(summary: summary, mayLandLate: result.axTimedOut || !answering)
            DispatchQueue.main.async { done(outcome) }
        }
    }

    /// The frame of the app's last (rightmost) menu in the menu bar, in global
    /// top-left coordinates, or nil when it has none or doesn't answer. Runs
    /// on the app's lane, like a title read.
    func lastMenuFrame(of pid: pid_t, _ done: @escaping (CGRect?) -> Void) {
        lane(pid).async {
            var frame: CGRect?
            defer { let f = frame; DispatchQueue.main.async { done(f) } }
            guard self.answering(pid) else { return }
            var bar: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXMenuBarAttribute as CFString, &bar)
            if err == .cannotComplete { self.noteTimeout(pid, "a menu bar read"); return }
            guard err == .success, let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
                  let items = children as? [AXUIElement] else { return }
            // The last item is normally Help; skip any that have no size.
            for item in items.reversed().prefix(3) {
                var values: CFArray?
                guard AXUIElementCopyMultipleAttributeValues(item, [kAXPositionAttribute, kAXSizeAttribute] as CFArray, [], &values) == .success,
                      let pair = values as? [AnyObject], pair.count == 2,
                      CFGetTypeID(pair[0]) == AXValueGetTypeID(), CFGetTypeID(pair[1]) == AXValueGetTypeID() else { continue }
                var origin = CGPoint.zero, size = CGSize.zero
                guard AXValueGetValue(pair[0] as! AXValue, .cgPoint, &origin),
                      AXValueGetValue(pair[1] as! AXValue, .cgSize, &size), size.width > 0 else { continue }
                frame = CGRect(origin: origin, size: size)
                return
            }
        }
    }

    // MARK: - Action lanes

    private func lane(_ pid: pid_t) -> DispatchQueue {
        laneLock.lock(); defer { laneLock.unlock() }
        if let queue = lanes[pid] { return queue }
        let queue = DispatchQueue(label: "dev.windowstrip.ax.action.\(pid)", qos: .userInteractive)
        lanes[pid] = queue
        return queue
    }

    private func nextToken(_ counter: ReferenceWritableKeyPath<AXWorker, Int>) -> Int {
        laneLock.lock(); defer { laneLock.unlock() }
        self[keyPath: counter] += 1
        return self[keyPath: counter]
    }

    private func isLatest(_ token: Int, _ counter: ReferenceWritableKeyPath<AXWorker, Int>) -> Bool {
        laneLock.lock(); defer { laneLock.unlock() }
        return self[keyPath: counter] == token
    }

    private func answering(_ pid: pid_t) -> Bool {
        laneLock.lock(); defer { laneLock.unlock() }
        guard let until = unresponsiveUntil[pid] else { return true }
        if uptimeNs() < until { return false }
        unresponsiveUntil[pid] = nil
        return true
    }

    private func noteTimeout(_ pid: pid_t, _ what: String) {
        laneLock.lock()
        unresponsiveUntil[pid] = uptimeNs() + 3_000_000_000
        laneLock.unlock()
        Log.info("ax", "pid \(pid) did not answer \(what); no AX actions for it for 3 s")
    }

    /// Logs a summary of the last minute, if anything happened.
    func logStats() {
        queries.async {
            let s = self.stats
            guard s.resolves + s.notifications + s.timeouts > 0 else { return }
            Log.info("stats", "ax: \(self.observers.count) apps watched, \(self.facts.count) windows known; last minute \(s.notifications) notifications, \(s.resolves) lookups (slowest \(ms(s.resolveMax))), \(s.titles) title changes, \(s.timeouts) timeouts")
            self.stats = (0, 0, 0, 0, 0)
        }
    }

    // MARK: - Query queue

    private func register(_ pid: pid_t) {
        guard observers[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier else { return }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        var observer: AXObserver?
        guard AXObserverCreate(pid, observerCallback, &observer) == .success, let observer else {
            Log.info("ax", "could not create an observer for \(name)")
            return
        }
        let app = AXUIElementCreateApplication(pid)
        var accepted = 0
        var lastError = AXError.success
        for notification in appLevelNotifications {
            let err = AXObserverAddNotification(observer, app, notification as CFString, nil)
            if err == .success || err == .notificationAlreadyRegistered || err == .notificationUnsupported {
                accepted += 1
            } else {
                lastError = err
                // Not answering: every further request would wait 0.5 s too.
                if err == .cannotComplete { break }
            }
        }
        guard accepted > 0, lastError != .cannotComplete else {
            // Still launching, busy, or it doesn't do AX. This observer and
            // anything registered on it are dropped; ask again later.
            if lastError == .cannotComplete { markSlow(pid, "a notification request", first: 0.5) }
            retryRegister(pid, name: name, error: lastError)
            return
        }
        CFRunLoopAddSource(observerRunLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        apps[pid, default: AppFacts()].observing = true
        registerAttempts[pid] = nil
        Log.debug("ax", "watching \(name) (pid \(pid))")
        resolveNow(pid, unknown: [], reason: "watch")
        publish(nil, "watch")
    }

    /// Asks an app that isn't watched yet again: often at first, since most
    /// apps answer within a few hundred ms of launching, then every 15, 30
    /// and 60 s for as long as it runs (a slow cold start, a busy app).
    private func retryRegister(_ pid: pid_t, name: String, error: AXError) {
        guard !registerRetry.contains(pid) else { return }   // one is already planned
        let attempt = (registerAttempts[pid] ?? 0) + 1
        registerAttempts[pid] = attempt
        let fast = [0.05, 0.05, 0.1, 0.1, 0.2, 0.25, 0.5, 1, 2, 4]
        var delay = attempt <= fast.count ? fast[attempt - 1] : 15 * Double(1 << min(2, attempt - fast.count - 1))
        // After a timeout the app isn't asked anything until its slow period
        // ends: each attempt can hold the shared query queue for 0.5 s.
        let until = apps[pid]?.slowUntil ?? 0, now = uptimeNs()
        if until > now { delay = max(delay, Double(until - now) / 1e9) }
        if attempt <= fast.count {
            Log.debug("ax", "\(name) not ready for AX (error \(error.rawValue)); retry \(attempt) in \(seconds(delay))")
        } else if attempt == fast.count + 1 {
            Log.info("ax", "\(name) has not accepted AX notifications (error \(error.rawValue)); its windows are shown without checks, and it is asked again every 15-60 s")
            apps[pid, default: AppFacts()].listsNoWindows = true
            publish(nil, "no-ax")
        }
        registerRetry.insert(pid)
        queries.asyncAfter(deadline: .now() + delay) {
            self.registerRetry.remove(pid)
            if isRunning(pid) { self.register(pid) }
        }
    }

    /// The app didn't answer within the AX timeout: its windows are shown
    /// unchecked and it isn't asked anything for `first` seconds (2 s, or
    /// 0.5 s for an app still launching), doubling on each further timeout up
    /// to 30 s, until a lookup gets through.
    private func markSlow(_ pid: pid_t, _ what: String, first: Double = 2) {
        stats.timeouts += 1
        let wait = min(30, backoff[pid].map { $0 * 2 } ?? first)
        backoff[pid] = wait
        apps[pid, default: AppFacts()].slowUntil = uptimeNs() + UInt64(wait * 1e9)
        Log.info("ax", "pid \(pid) did not answer \(what); showing its windows unchecked for \(seconds(wait))")
    }

    /// `unknown` are windows the bar has no facts for. `onScreen` says they
    /// were on screen just now; only then does an empty list mean the app
    /// lists no windows (an AX event's leftovers may be on another Space).
    private func resolveNow(_ pid: pid_t, unknown: Set<CGWindowID>, reason: String, onScreen: Bool = true) {
        let start = uptimeNs()
        lastResolve[pid] = start
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        let took = msSince(start)
        stats.resolves += 1
        stats.resolveMax = max(stats.resolveMax, took)

        if err == .cannotComplete {
            markSlow(pid, "a window list request (\(ms(took)))")
            return
        }
        // Any other error counts as an empty list: AX can't tell this app's
        // windows apart, so they are shown, and checked again like any
        // window missing from a list.
        if err != .success { Log.debug("ax", "pid \(pid) window list error \(err.rawValue)") }
        let windows = err == .success ? (value as? [AXUIElement] ?? []) : []
        apps[pid, default: AppFacts()].slowUntil = 0
        if !windows.isEmpty {
            apps[pid, default: AppFacts()].listsNoWindows = false
        } else if onScreen && !unknown.isEmpty {
            apps[pid, default: AppFacts()].listsNoWindows = true
        }

        var seen = Set<CGWindowID>()
        for element in windows {
            var id: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &id) == .success, id != 0 else { continue }  // e.g. Finder's desktop
            seen.insert(id)
            // New windows are learned; known ones that aren't watched yet (learned
            // before the app's observer existed) are watched now.
            let answered = facts[id]?.listed != true ? learn(id, pid: pid, element: element)
                                                     : watch(id, pid: pid, element: element)
            // It stopped answering: the rest waits for the next lookup, and
            // windows not reached yet are not counted as missing from the list.
            if !answered { return }
        }
        // Every read got through: the next timeout starts the backoff afresh.
        backoff[pid] = nil
        let now = uptimeNs()
        for id in unknown where !seen.contains(id) {
            var f = facts[id] ?? WindowFacts(pid: pid, listed: false, subrole: nil, title: nil, checkedAt: now, checks: 0)
            guard !f.listed else { continue }
            f.checkedAt = now
            f.checks += 1
            facts[id] = f
            Log.debug("ax", "window #\(id) of pid \(pid) is on screen but not in its AX list (check \(f.checks))")
        }
        if took > 40 {
            Log.info("ax", "pid \(pid) took \(ms(took)) to list \(windows.count) windows (\(reason))")
        } else {
            Log.debug("ax", "listed pid \(pid): \(windows.count) windows in \(ms(took)) (\(reason))")
        }
    }

    /// Reads a window's subrole and title, then watches it. Returns false
    /// when the app stopped answering. A subrole read that timed out records
    /// nothing, so the window is shown unchecked and asked about again later
    /// instead of being taken for a non-document window for good.
    @discardableResult
    private func learn(_ id: CGWindowID, pid: pid_t, element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        if err == .cannotComplete { markSlow(pid, "a subrole read"); return false }
        let subrole = err == .success ? value as? String : nil
        var titleValue: CFTypeRef?
        let titleErr = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue)
        let checks = (facts[id]?.checks ?? 0) + 1
        facts[id] = WindowFacts(pid: pid, listed: true, subrole: subrole, title: titleValue as? String, checkedAt: uptimeNs(), checks: checks)
        elementLock.lock(); elements[id] = element; elementLock.unlock()
        Log.debug("ax", "window #\(id) pid \(pid): \(subrole ?? "no subrole")")
        if titleErr == .cannotComplete { markSlow(pid, "a title read"); return false }
        return watch(id, pid: pid, element: element)
    }

    /// Asks for a window's close, minimise, restore and title notifications,
    /// once, when its app has an observer. Returns false when the app stopped
    /// answering; the window is then tried again on the next lookup.
    @discardableResult
    private func watch(_ id: CGWindowID, pid: pid_t, element: AXUIElement) -> Bool {
        guard !watched.contains(id), let observer = observers[pid] else { return true }
        let refcon = UnsafeMutableRawPointer(bitPattern: UInt(id))
        var ok = 0
        for notification in windowLevelNotifications {
            let err = AXObserverAddNotification(observer, element, notification as CFString, refcon)
            if err == .cannotComplete { markSlow(pid, "a notification request"); return false }
            if err == .success || err == .notificationAlreadyRegistered || err == .notificationUnsupported { ok += 1 }
        }
        // Tried once either way; the list catches up with windows that refuse.
        watched.insert(id)
        if ok == 0 { Log.debug("ax", "window #\(id) pid \(pid) accepted no notifications") }
        return true
    }

    /// A window that wasn't a document window when first seen is asked again
    /// when it gets focus, since a subrole can still change after it opens.
    private func recheckSubrole(_ id: CGWindowID, pid: pid_t, element: AXUIElement) {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value)
        if err == .cannotComplete { markSlow(pid, "a subrole read"); return }
        guard err == .success, let subrole = value as? String, subrole != facts[id]?.subrole else { return }
        Log.info("ax", "window #\(id) pid \(pid): subrole is now \(subrole) (was \(facts[id]?.subrole ?? "none"))")
        facts[id]?.subrole = subrole
    }

    /// On-screen windows the app left out of its AX list, past their timed
    /// rechecks, are asked about again when the app sends an AX event (at most
    /// every 250 ms): some apps list a window only a while after showing it.
    private func recheckUnlisted(_ pid: pid_t) {
        let unlisted = Set(facts.filter { $0.value.pid == pid && !$0.value.listed && $0.value.checks >= 3 }.keys)
        guard !unlisted.isEmpty, msSince(lastResolve[pid] ?? 0) >= 250 else { return }
        resolveNow(pid, unknown: unlisted, reason: "event", onScreen: false)
    }

    private func drop(_ id: CGWindowID) {
        facts[id] = nil
        watched.remove(id)
        elementLock.lock(); elements[id] = nil; elementLock.unlock()
    }

    // MARK: - Observer callbacks (arrive on the observer thread)

    fileprivate func received(_ notification: String, _ element: AXUIElement, _ refconWindow: CGWindowID) {
        queries.async { self.handle(notification, element, refconWindow) }
    }

    private func handle(_ notification: String, _ element: AXUIElement, _ refconWindow: CGWindowID) {
        stats.notifications += 1
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let name = short(notification)

        switch notification {
        case kAXUIElementDestroyedNotification:
            let pidOfWindow = facts[refconWindow]?.pid ?? pid
            drop(refconWindow)
            Log.debug("axn", "closed #\(refconWindow) pid \(pidOfWindow)")
            publish(.closed(refconWindow), "ax:closed")
        case kAXWindowMiniaturizedNotification:
            Log.debug("axn", "minimized #\(refconWindow) pid \(pid)")
            publish(.minimized(refconWindow), "ax:minimized")
        case kAXWindowDeminiaturizedNotification:
            Log.debug("axn", "restored #\(refconWindow) pid \(pid)")
            publish(.restored(refconWindow), "ax:restored")
        case kAXTitleChangedNotification:
            stats.titles += 1
            let title = facts[refconWindow] != nil ? string(element, kAXTitleAttribute) : nil
            if facts[refconWindow] != nil { facts[refconWindow]?.title = title }
            // Titles feed the tooltip and the tab matching, so no refresh; a
            // browser's tabs may have changed.
            if let onTitleChange { DispatchQueue.main.async { onTitleChange(pid, refconWindow, title) } }
        case kAXApplicationHiddenNotification:
            Log.debug("axn", "hidden pid \(pid)")
            publish(.hidden(pid), "ax:hidden")
        case kAXApplicationShownNotification:
            Log.debug("axn", "shown pid \(pid)")
            publish(.shown(pid), "ax:shown")
        default:
            // Window created / focused / main changed: the element is the window.
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(element, &id) == .success, id != 0 {
                let isNew = facts[id]?.listed != true
                // A slow app is not asked anything; its windows are shown unchecked.
                if (apps[pid]?.slowUntil ?? 0) <= uptimeNs() {
                    if isNew {
                        learn(id, pid: pid, element: element)
                    } else if notification != kAXWindowCreatedNotification, facts[id]?.isDocument == false {
                        recheckSubrole(id, pid: pid, element: element)
                    }
                    // The read above may have timed out: then don't ask again now.
                    if (apps[pid]?.slowUntil ?? 0) <= uptimeNs() { recheckUnlisted(pid) }
                }
                Log.debug("axn", "\(name) #\(id) pid \(pid)\(isNew ? " (new)" : "")")
                publish(notification == kAXWindowCreatedNotification ? .created(id, pid) : .focused(id, pid), "ax:\(name)")
            } else {
                Log.debug("axn", "\(name) pid \(pid) (no window id)")
                publish(.focused(nil, pid), "ax:\(name)")
            }
        }
    }

    private func short(_ notification: String) -> String {
        notification.replacingOccurrences(of: "AX", with: "").replacingOccurrences(of: "Notification", with: "")
    }

    private func publish(_ event: AXEvent?, _ reason: String) {
        let update = AXUpdate(facts: facts, apps: apps, event: event, reason: reason)
        DispatchQueue.main.async { self.onUpdate?(update) }
    }

    // MARK: - Action queue

    /// The AX element of a window: from the cache, else by listing the app's
    /// windows here on the calling queue.
    private func element(_ id: CGWindowID, _ pid: pid_t) -> AXUIElement? {
        elementLock.lock()
        let cached = elements[id]
        elementLock.unlock()
        if let cached { return cached }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        if err == .cannotComplete { noteTimeout(pid, "a window lookup") }
        guard err == .success, let windows = value as? [AXUIElement] else { return nil }
        for element in windows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(element, &wid) == .success, wid == id { return element }
        }
        return nil
    }
}

/// "500 ms", "2 s".
private func seconds(_ s: Double) -> String { s < 1 ? "\(Int(s * 1000)) ms" : "\(Int(s)) s" }

/// True while a process with this pid exists (safe on any thread).
func isRunning(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

func string(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
}
