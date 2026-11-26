// Site icons for browser windows: the strip shows up to three of a browser
// window's tab icons (the active tab's first) in place of the browser's own
// icon.
//
// Tabs come from the browser over Apple events, through the Chromium
// scripting dictionary (Helium, Chrome, Brave, Edge, Chromium, Vivaldi): every
// window's bounds, name, minimized flag, active tab index and tab URLs. macOS
// asks the user once to allow this (Privacy & Security > Automation). Icons
// come from the browser's own favicon database (the Favicons SQLite file in
// each profile), opened read-only without taking a lock. Nothing goes over the
// network, and no URL or title is ever logged.

import AppKit
import SQLite3

/// A browser window as the browser's scripting dictionary describes it.
struct BrowserWindow {
    /// As the browser reports it; see `Controller.applyTabs` for matching.
    let bounds: CGRect
    let name: String
    let minimized: Bool
    /// 1-based, as in AppleScript.
    let activeTab: Int
    let urls: [String]
}

/// One browser window's icons: up to three, the active tab's first. nil
/// stands for the browser's own icon (an active tab with no site icon, such
/// as a new tab page). Empty when no tab has a site icon.
typealias TabIcons = [FaviconStore.Icon?]

enum Browsers {
    /// Bundle id → profile folder under ~/Library/Application Support.
    static let chromium: [String: String] = [
        "net.imput.helium": "net.imput.helium",
        "com.google.Chrome": "Google/Chrome",
        "com.brave.Browser": "BraveSoftware/Brave-Browser",
        "com.microsoft.edgemac": "Microsoft Edge",
        "org.chromium.Chromium": "Chromium",
        "com.vivaldi.Vivaldi": "Vivaldi",
    ]
}

/// What a read of a browser's tabs came to.
enum TabRead {
    case windows([(window: BrowserWindow, icons: TabIcons)])
    /// Not this time: busy, quit, or its windows changed during the read.
    case failed
    /// WindowStrip may not send this browser Apple events.
    case denied
}

final class TabReader {
    /// Utility QoS: icons are a nicety, never in the way of a click.
    private let queue = DispatchQueue(label: "dev.windowstrip.tabs", qos: .utility)
    // Owned by `queue`.
    private var permission: [String: (allowed: Bool, at: UInt64)] = [:]
    private let favicons = FaviconStore()

    /// Reads a browser's windows and picks each one's icons, then calls back
    /// on main. Events go to the running process, so they never launch the
    /// browser.
    func read(pid: pid_t, bundleID: String, _ done: @escaping (TabRead) -> Void) {
        queue.async {
            let start = uptimeNs()
            let target = NSAppleEventDescriptor(processIdentifier: pid)
            guard let root = Browsers.chromium[bundleID], self.mayAutomate(bundleID, target),
                  let windows = self.windows(of: target, bundleID) else {
                let denied = self.permission[bundleID]?.allowed == false
                DispatchQueue.main.async { done(denied ? .denied : .failed) }
                return
            }
            let result = windows.map { (window: $0, icons: self.pick($0, root: root)) }
            let tabs = windows.reduce(0) { $0 + $1.urls.count }
            let icons = result.reduce(0) { $0 + $1.icons.compactMap { $0 }.count }
            Log.debug("tabs", "\(bundleID): \(windows.count) windows, \(tabs) tabs, \(icons) site icons in \(ms(msSince(start)))")
            DispatchQueue.main.async { done(.windows(result)) }
        }
    }

    // MARK: - Permission (queue)

    /// Asks macOS once whether this app may send the browser Apple events;
    /// the first time, macOS asks the user (the queue waits for the answer).
    /// A "no" is checked again every minute without asking, so allowing it
    /// later in System Settings works without a restart.
    private func mayAutomate(_ bundleID: String, _ target: NSAppleEventDescriptor) -> Bool {
        let now = uptimeNs()
        if let p = permission[bundleID], p.allowed || now &- p.at < 60_000_000_000 { return p.allowed }
        guard let desc = target.aeDesc else { return false }
        let status = AEDeterminePermissionToAutomateTarget(desc, code("core"), code("getd"), permission[bundleID] == nil)
        if status == OSStatus(procNotFound) { return false }   // not running: ask next time
        let allowed = status == noErr
        if permission[bundleID]?.allowed != allowed {
            Log.info("tabs", "\(bundleID): reading tabs is \(allowed ? "allowed" : "not allowed (\(status))")")
        }
        permission[bundleID] = (allowed, now)
        return allowed
    }

    // MARK: - Apple events (queue)

    /// Five requests, each one round trip: bounds, names, minimized flags and
    /// active tab indexes of every window, then the URLs of every tab.
    private func windows(of target: NSAppleEventDescriptor, _ bundleID: String) -> [BrowserWindow]? {
        let all = every("cwin", in: nil)
        guard let bounds = get(property("pbnd", of: all), from: target, bundleID),
              let names = get(property("pnam", of: all), from: target, bundleID),
              let minimized = get(property("pmnd", of: all), from: target, bundleID),
              let active = get(property("acTI", of: all), from: target, bundleID),
              let urls = get(property("URL ", of: every("CrTb", in: all)), from: target, bundleID) else { return nil }
        let b = items(bounds), n = items(names), m = items(minimized), a = items(active), u = items(urls)
        // A window opened or closed between the requests: read again next time.
        guard b.count == n.count, b.count == m.count, b.count == a.count, b.count == u.count else { return nil }
        // With several windows, their order can change between the requests
        // (the user clicks another one), which would pair one window's tabs with
        // another's frame: the frames must come back the same way.
        if b.count > 1 {
            guard let again = get(property("pbnd", of: all), from: target, bundleID),
                  items(again).map(rect) == b.map(rect) else { return nil }
        }
        return b.indices.compactMap { i in
            guard let r = rect(b[i]) else { return nil }
            return BrowserWindow(bounds: r, name: n[i].stringValue ?? "", minimized: m[i].booleanValue,
                                 activeTab: Int(a[i].int32Value), urls: items(u[i]).compactMap(\.stringValue))
        }
    }

    private func get(_ specifier: NSAppleEventDescriptor, from target: NSAppleEventDescriptor, _ bundleID: String) -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor(eventClass: code("core"), eventID: code("getd"),
                                           targetDescriptor: target,
                                           returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(specifier, forKeyword: keyDirectObject)
        do {
            // Never prompts (kAEDoNotPromptForUserConsent): only `mayAutomate`
            // asks the user, once.
            let options: NSAppleEventDescriptor.SendOptions = [.waitForReply, .neverInteract, .init(rawValue: 0x0002_0000)]
            let reply = try event.sendEvent(options: options, timeout: 1.5)
            return reply.paramDescriptor(forKeyword: keyDirectObject)
        } catch {
            let code = (error as NSError).code
            if code == -1743 || code == -1744 {
                // Turned off in System Settings while running: stop sending
                // until `mayAutomate` sees it allowed again.
                permission[bundleID] = (false, uptimeNs())
                Log.info("tabs", "\(bundleID): reading tabs is no longer allowed (\(code))")
            } else {
                Log.info("tabs", "\(bundleID): a tab request failed (error \(code))")
            }
            return nil
        }
    }

    /// `every <class>` of `container` (the application when nil).
    private func every(_ cls: String, in container: NSAppleEventDescriptor?) -> NSAppleEventDescriptor {
        var all = code("all ")
        let ordinal = NSAppleEventDescriptor(descriptorType: code("abso"), bytes: &all, length: 4)!
        return specifier(cls, form: "indx", data: ordinal, in: container)
    }

    /// `<property> of <container>`.
    private func property(_ prop: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier("prop", form: "prop", data: NSAppleEventDescriptor(typeCode: code(prop)), in: container)
    }

    private func specifier(_ cls: String, form: String, data: NSAppleEventDescriptor, in container: NSAppleEventDescriptor?) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(cls)), forKeyword: code("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        record.setDescriptor(data, forKeyword: code("seld"))
        record.setDescriptor(container ?? NSAppleEventDescriptor.null(), forKeyword: code("from"))
        return record.coerce(toDescriptorType: code("obj ")) ?? record
    }

    private func items(_ d: NSAppleEventDescriptor) -> [NSAppleEventDescriptor] {
        guard d.descriptorType == code("list"), d.numberOfItems > 0 else { return [] }
        return (1...d.numberOfItems).compactMap { d.atIndex($0) }
    }

    /// A window's bounds: a QuickDraw rectangle (top, left, bottom, right)
    /// or a list {left, top, right, bottom}, depending on the browser.
    private func rect(_ d: NSAppleEventDescriptor) -> CGRect? {
        if d.descriptorType == code("qdrt"), d.data.count == 8 {
            let v = d.data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
            return CGRect(x: Double(v[1]), y: Double(v[0]), width: Double(v[3]) - Double(v[1]), height: Double(v[2]) - Double(v[0]))
        }
        let v = items(d).map { Double($0.int32Value) }
        guard v.count == 4 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2] - v[0], height: v[3] - v[1])
    }

    // MARK: - Picking icons (queue)

    /// Up to three icons: the active tab's, then other tabs' in tab order,
    /// each icon once (tabs of one site usually share it).
    private func pick(_ w: BrowserWindow, root: String) -> TabIcons {
        guard !w.urls.isEmpty else { return [] }
        let active = min(max(w.activeTab, 1), w.urls.count) - 1
        var picked: TabIcons = []
        var seen = Set<Int64>()
        for i in [active] + w.urls.indices.filter({ $0 != active }) {
            if let icon = favicons.icon(for: w.urls[i], root: root) {
                guard seen.insert(icon.id).inserted else { continue }
                picked.append(icon)
            } else if i == active {
                picked.append(nil)
            }
            if picked.count == 3 { break }
        }
        return picked.contains { $0 != nil } ? picked : []
    }
}

private func code(_ s: String) -> FourCharCode { s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) } }

/// Favicons from a Chromium browser's own database. Used only on the tab
/// reader's queue.
final class FaviconStore {
    struct Icon { let id: Int64; let image: NSImage }

    private var cache: [String: (icon: Icon?, exact: Bool, at: UInt64)] = [:]
    private var databases: [String: (handle: OpaquePointer, stamp: [Int])] = [:]
    private var profiles: (root: String, paths: [String], at: UInt64)?

    /// The icon the browser keeps for `url`'s page, else the latest one for
    /// its site. Only the page's own icon is kept for good: a miss or a
    /// site's icon (on a host with several, Docs and Sheets say, it can be
    /// the wrong one) is looked up again after 30 s, since the browser adds
    /// a new page's icon some seconds after it loads.
    func icon(for url: String, root: String) -> Icon? {
        let now = uptimeNs()
        if let c = cache[url], c.exact || now &- c.at < 30_000_000_000 { return c.icon }
        if cache.count > 500 { cache = [:] }
        var found: Icon?, exact = false
        if let site = FaviconStore.site(of: url) {
            for path in profilePaths(root, now: now) {
                guard let db = database(path) else { continue }
                if let icon = lookup(db, exact: url) { found = icon; exact = true; break }
                if found == nil { found = lookup(db, site: site) }
            }
        }
        cache[url] = (found, exact, now)
        return found
    }

    /// "https://host" for web pages; nil for anything else (new tab page,
    /// browser pages, files), which has no site icon.
    static func site(of url: String) -> String? {
        guard let u = URL(string: url), let scheme = u.scheme, scheme == "https" || scheme == "http", let host = u.host else { return nil }
        return "\(scheme)://\(host)\(u.port.map { ":\($0)" } ?? "")"
    }

    private func profilePaths(_ root: String, now: UInt64) -> [String] {
        if let p = profiles, p.root == root, now &- p.at < 60_000_000_000 { return p.paths }
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/\(root)")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []
        let paths = names.filter { $0 == "Default" || $0.hasPrefix("Profile ") }.sorted()
            .map { base.appendingPathComponent($0).appendingPathComponent("Favicons").path }
            .filter { FileManager.default.isReadableFile(atPath: $0) }
        profiles = (root, paths, now)
        return paths
    }

    /// Opened read-only and immutable: no locks, so a running browser is
    /// never blocked and one that holds its database exclusively can still be
    /// read. Immutable also means SQLite never notices the browser's writes,
    /// so the file is opened again whenever its size or time changes.
    private func database(_ path: String) -> OpaquePointer? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let stamp = [Int(truncatingIfNeeded: st.st_ino), Int(st.st_size), st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec]
        if let d = databases[path] {
            if d.stamp == stamp { return d.handle }
            sqlite3_close(d.handle)
            databases[path] = nil
        }
        let uri = URL(fileURLWithPath: path).absoluteString + "?mode=ro&immutable=1"
        var handle: OpaquePointer?
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        databases[path] = (handle, stamp)
        return handle
    }

    private func lookup(_ db: OpaquePointer, exact url: String) -> Icon? {
        query(db, """
            SELECT m.icon_id, b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE m.page_url = ?1 AND length(b.image_data) > 0 ORDER BY abs(b.width - 32) LIMIT 1
            """, [url])
    }

    /// The most recently mapped icon of any page on the site (a range scan on
    /// the page_url index: "https://host/" up to "https://host0").
    private func lookup(_ db: OpaquePointer, site: String) -> Icon? {
        query(db, """
            SELECT m.icon_id, b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id
            WHERE m.page_url >= ?1 AND m.page_url < ?2 AND length(b.image_data) > 0
            ORDER BY m.id DESC, abs(b.width - 32) LIMIT 1
            """, [site + "/", site + "0"])
    }

    private func query(_ db: OpaquePointer, _ sql: String, _ args: [String]) -> Icon? {
        var stmt: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard prepared == SQLITE_OK, let stmt else {
            Log.debug("tabs", "a favicon lookup failed (sqlite \(prepared))")
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)   // SQLITE_TRANSIENT
        for (i, arg) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, transient) }
        let step = sqlite3_step(stmt)
        if step != SQLITE_ROW && step != SQLITE_DONE { Log.debug("tabs", "a favicon lookup failed (sqlite \(step))") }
        guard step == SQLITE_ROW, let blob = sqlite3_column_blob(stmt, 1) else { return nil }
        let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1)))
        guard let image = NSImage(data: data) else { return nil }
        return Icon(id: sqlite3_column_int64(stmt, 0), image: image)
    }
}
