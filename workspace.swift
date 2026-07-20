import Cocoa
import ApplicationServices

// MARK: - Additional private APIs for window management

@_silgen_name("SLSCopySpacesForWindows")
func _SLSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: UInt32, _ wids: CFArray) -> Unmanaged<CFArray>?
func SLSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: UInt32, _ wids: CFArray) -> CFArray? {
    _SLSCopySpacesForWindows(cid, mask, wids)?.takeRetainedValue()
}

/// Bridges AX windows to CGWindowIDs (private HIServices export).
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<UInt32>) -> AXError

// MARK: - Workspace model

struct WindowRec: Codable {
    let bundleID: String
    let appName: String
    let title: String
    let wid: UInt32
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let spaceUUID: String
    let spaceName: String?
    let spacePosition: Int
    let minimized: Bool
    let urls: [String]?
    var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct WorkspaceSnapshot: Codable {
    var version: Int = 1
    var date: Date = Date()
    var windows: [WindowRec]
}

// MARK: - WorkspaceEngine

final class WorkspaceEngine {
    private let conn = CGSMainConnectionID()
    private let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpaceNamer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("workspace.json")
    }()

    var snapshotExists: Bool { FileManager.default.fileExists(atPath: storeURL.path) }

    struct SnapshotInfo {
        let date: Date
        let windowCount: Int
        let appCount: Int
        let perDesktop: [(spaceLabel: String, bundleIDs: [String])]
    }

    func snapshotInfo() -> SnapshotInfo? {
        guard let data = try? Data(contentsOf: storeURL),
              let snap = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data) else { return nil }
        let apps = Set(snap.windows.map { $0.bundleID })
        var per: [(uuid: String, pos: Int, label: String, bundleIDs: [String])] = []
        for w in snap.windows {
            if let i = per.firstIndex(where: { $0.uuid == w.spaceUUID }) {
                if !per[i].bundleIDs.contains(w.bundleID) { per[i].bundleIDs.append(w.bundleID) }
            } else {
                per.append((w.spaceUUID, w.spacePosition,
                            w.spaceName ?? "Desktop \(w.spacePosition + 1)", [w.bundleID]))
            }
        }
        per.sort { $0.pos < $1.pos }
        return SnapshotInfo(date: snap.date, windowCount: snap.windows.count, appCount: apps.count,
                            perDesktop: per.map { ($0.label, $0.bundleIDs) })
    }

    var restoreAtLogin: Bool {
        get { UserDefaults.standard.bool(forKey: "WorkspaceRestoreAtLogin") }
        set { UserDefaults.standard.set(newValue, forKey: "WorkspaceRestoreAtLogin") }
    }

    static func accessibilityTrusted(prompt: Bool) -> Bool {
        let opts: CFDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: AX helpers

    private func axAttr<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? T
    }

    private func axFrame(_ el: AXUIElement) -> CGRect? {
        guard let posRef: AXValue = axAttr(el, kAXPositionAttribute as String),
              let sizeRef: AXValue = axAttr(el, kAXSizeAttribute as String) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(posRef, .cgPoint, &p),
              AXValueGetValue(sizeRef, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private func axSetFrame(_ el: AXUIElement, _ rect: CGRect) {
        var s = rect.size, p = rect.origin
        guard let sv = AXValueCreate(.cgSize, &s), let pv = AXValueCreate(.cgPoint, &p) else { return }
        // size → position → size again: some apps clamp oddly otherwise
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv)
        AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv)
        AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv)
    }

    private func axWindowID(_ el: AXUIElement) -> UInt32? {
        var wid: UInt32 = 0
        return _AXUIElementGetWindow(el, &wid) == .success ? wid : nil
    }

    private func spacesOf(window wid: UInt32) -> [CGSSpaceID] {
        guard let arr = SLSCopySpacesForWindows(conn, 0x7, [NSNumber(value: wid)] as CFArray) as? [NSNumber] else { return [] }
        return arr.map { $0.uint64Value }
    }

    // MARK: Live per-space apps (panel rows)

    /// Bundle IDs of apps with windows on each space (front-to-back order),
    /// keyed by space UUID. Same CGWindowList + CGS walk as capture — cheap
    /// enough to run on panel open.
    func liveApps(spaces: [Space]) -> [String: [String]] {
        let spaceByManagedID: [CGSSpaceID: Space] = Dictionary(uniqueKeysWithValues: spaces.map { ($0.managedID, $0) })
        guard let winList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var out: [String: [String]] = [:]
        var bidByPid: [pid_t: String] = [:]
        var skippedPids: Set<pid_t> = []
        for w in winList {
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pidNum = w[kCGWindowOwnerPID as String] as? NSNumber,
                  let widNum = w[kCGWindowNumber as String] as? NSNumber,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  b.width > 50, b.height > 50 else { continue }
            let pid = pidNum.int32Value
            if skippedPids.contains(pid) { continue }
            let bid: String
            if let known = bidByPid[pid] {
                bid = known
            } else if let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular,
                      let b = app.bundleIdentifier, b != Bundle.main.bundleIdentifier {
                bidByPid[pid] = b
                bid = b
            } else {
                skippedPids.insert(pid)
                continue
            }
            guard let sid = spacesOf(window: widNum.uint32Value).first(where: { spaceByManagedID[$0] != nil }),
                  let space = spaceByManagedID[sid] else { continue }
            if out[space.uuid]?.contains(bid) != true {
                out[space.uuid, default: []].append(bid)
            }
        }
        return out
    }

    // MARK: Capture

    struct CaptureResult {
        let windowCount: Int
        let appCount: Int
        let path: String
        var browserURLsDenied: Bool = false
        var errorMessage: String? = nil
    }

    @discardableResult
    func capture(spaces: [Space]) -> CaptureResult {
        var records: [WindowRec] = []
        var browserURLsDenied = false
        let spaceByManagedID: [CGSSpaceID: Space] = Dictionary(uniqueKeysWithValues: spaces.map { ($0.managedID, $0) })

        // AX only exposes an app's windows on the *current* space (plus
        // minimized ones), so a pure-AX walk captures a single desktop.
        // Enumerate the whole session via CGWindowList instead — it sees every
        // desktop on every display — and enrich with AX (exact title,
        // minimized state, subrole filter) where AX can reach.
        guard let winList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return CaptureResult(
                windowCount: 0,
                appCount: 0,
                path: storeURL.path,
                errorMessage: "macOS did not return a window list"
            )
        }

        final class AppCtx {
            let app: NSRunningApplication
            let bundleID: String
            var axByWid: [UInt32: AXUIElement] = [:]
            var browser: [(bounds: CGRect, urls: [String])] = []
            var isBrowser: Bool { bundleID.hasPrefix("com.google.Chrome") || bundleID == "com.apple.Safari" }
            init(app: NSRunningApplication, bundleID: String) { self.app = app; self.bundleID = bundleID }
        }
        var ctxByPid: [pid_t: AppCtx] = [:]
        var skipped: Set<pid_t> = []

        for w in winList {
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pidNum = w[kCGWindowOwnerPID as String] as? NSNumber,
                  let widNum = w[kCGWindowNumber as String] as? NSNumber,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            let pid = pidNum.int32Value
            let wid = widNum.uint32Value
            if skipped.contains(pid) { continue }

            let ctx: AppCtx
            if let existing = ctxByPid[pid] {
                ctx = existing
            } else {
                guard let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular,
                      let bid = app.bundleIdentifier,
                      bid != Bundle.main.bundleIdentifier else {
                    skipped.insert(pid)
                    continue
                }
                let c = AppCtx(app: app, bundleID: bid)
                if let axWins: [AXUIElement] = axAttr(AXUIElementCreateApplication(pid), kAXWindowsAttribute as String) {
                    for el in axWins {
                        if let w = axWindowID(el) { c.axByWid[w] = el }
                    }
                }
                if c.isBrowser {
                    let (pairs, denied) = captureBrowserURLs(bundleID: bid)
                    c.browser = pairs
                    if denied { browserURLsDenied = true }
                }
                ctxByPid[pid] = c
                ctx = c
            }

            let ax = ctx.axByWid[wid]
            // standard windows only where AX can tell (skip panels, sheets)
            if let ax, let subrole: String = axAttr(ax, kAXSubroleAttribute as String),
               subrole != kAXStandardWindowSubrole { continue }
            let frame = ax.flatMap { axFrame($0) } ?? cgBounds
            guard frame.width > 50 && frame.height > 50 else { continue }

            // which of OUR spaces is this window on?
            let winSpaces = spacesOf(window: wid)
            guard let sid = winSpaces.first(where: { spaceByManagedID[$0] != nil }),
                  let space = spaceByManagedID[sid] else { continue }
            if space.isFullScreen { continue } // can't restore fullscreen state

            let title: String = ax.flatMap { axAttr($0, kAXTitleAttribute as String) }
                ?? (w[kCGWindowName as String] as? String) ?? ""
            let minimized = ax.flatMap { (axAttr($0, "AXMinimized") as NSNumber?)?.boolValue } ?? false
            var urls: [String]?
            if ctx.isBrowser, let i = Self.closestBrowserWindow(ctx.browser, to: frame) {
                urls = ctx.browser.remove(at: i).urls
            }

            records.append(WindowRec(
                bundleID: ctx.bundleID,
                appName: ctx.app.localizedName ?? ctx.bundleID,
                title: title,
                wid: wid,
                x: frame.origin.x, y: frame.origin.y,
                w: frame.size.width, h: frame.size.height,
                spaceUUID: space.uuid,
                spaceName: space.customName,
                spacePosition: space.positionOnDisplay,
                minimized: minimized,
                urls: urls?.isEmpty == false ? urls : nil
            ))
        }

        let snap = WorkspaceSnapshot(windows: records)
        let apps = Set(records.map { $0.bundleID })
        do {
            try writeJSONAtomically(snap, to: storeURL)
        } catch {
            return CaptureResult(
                windowCount: records.count,
                appCount: apps.count,
                path: storeURL.path,
                browserURLsDenied: browserURLsDenied,
                errorMessage: error.localizedDescription
            )
        }
        return CaptureResult(windowCount: records.count, appCount: apps.count, path: storeURL.path, browserURLsDenied: browserURLsDenied)
    }

    // MARK: Restore

    func restore(currentSpaces: @escaping () -> [Space], status: @escaping (String) -> Void) {
        guard let data = try? Data(contentsOf: storeURL),
              let snap = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data) else {
            status("No saved workspace found")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.performRestore(snap: snap, currentSpaces: currentSpaces, status: status)
        }
    }

    private func performRestore(snap: WorkspaceSnapshot, currentSpaces: @escaping () -> [Space], status: @escaping (String) -> Void) {
        let spaces = currentSpaces()
        let byUUID = Dictionary(uniqueKeysWithValues: spaces.map { ($0.uuid, $0) })
        let originalCurrent = spaces.first(where: { $0.isCurrent })

        func targetSpace(for rec: WindowRec) -> Space? {
            if let s = byUUID[rec.spaceUUID] { return s }
            if let name = rec.spaceName, let s = spaces.first(where: { $0.customName == name }) { return s }
            return spaces.first(where: { $0.positionOnDisplay == rec.spacePosition && $0.displayIndex == 0 })
        }

        struct AppWindows {
            let app: NSRunningApplication
            var windows: [(el: AXUIElement, wid: UInt32, title: String, onSpace: Bool)]
        }
        func windowsOf(_ bundleID: String, onSpace space: Space) -> AppWindows? {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return nil }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            guard let axWindows: [AXUIElement] = axAttr(axApp, kAXWindowsAttribute as String) else {
                return AppWindows(app: app, windows: [])
            }
            let wins = axWindows.compactMap { w -> (AXUIElement, UInt32, String, Bool)? in
                guard let wid = axWindowID(w) else { return nil }
                let t: String = axAttr(w, kAXTitleAttribute as String) ?? ""
                let onThis = spacesOf(window: wid).contains(space.managedID)
                return (w, wid, t, onThis)
            }
            return AppWindows(app: app, windows: wins)
        }

        // group saved windows by target desktop, in desktop order
        var grouped: [(Space, [WindowRec])] = []
        for rec in snap.windows {
            guard let space = targetSpace(for: rec) else { continue }
            if let i = grouped.firstIndex(where: { $0.0.uuid == space.uuid }) {
                grouped[i].1.append(rec)
            } else {
                grouped.append((space, [rec]))
            }
        }
        grouped.sort { (a, b) in a.0.positionOnDisplay < b.0.positionOnDisplay }

        var placed = 0, launchedApps: Set<String> = [], leftBehind = 0

        for (space, recs) in grouped {
            // visit the desktop: switch so launches/new windows land there
            CGSManagedDisplaySetCurrentSpace(conn, space.displayID as CFString, space.managedID)
            Thread.sleep(forTimeInterval: 0.6)

            // launch missing apps for this desktop
            for rec in recs where !launchedApps.contains(rec.bundleID) {
                if NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == rec.bundleID }) == nil,
                   let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rec.bundleID) {
                    let cfg = NSWorkspace.OpenConfiguration()
                    cfg.activates = true
                    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in }
                    launchedApps.insert(rec.bundleID)
                }
            }
            // recreate browser windows that had URLs but no live window here
            for rec in recs {
                guard let urls = rec.urls, !urls.isEmpty else { continue }
                let live = windowsOf(rec.bundleID, onSpace: space)
                let hasWindowHere = live?.windows.contains { $0.onSpace && ($0.title == rec.title || rec.title.isEmpty) } ?? false
                if !hasWindowHere {
                    createBrowserWindow(bundleID: rec.bundleID, urls: urls)
                    Thread.sleep(forTimeInterval: 1.2)
                }
            }
            // wait for windows to materialize on this space (poll)
            var attempts = 0
            while attempts < 16 {
                let missing = recs.contains { rec in
                    guard let live = windowsOf(rec.bundleID, onSpace: space) else { return true }
                    return !live.windows.contains { $0.onSpace && ($0.title == rec.title || $0.1 == rec.wid || rec.title.isEmpty) }
                }
                if !missing { break }
                attempts += 1
                Thread.sleep(forTimeInterval: 0.5)
            }
            // position every saved window that is on this space
            for rec in recs {
                guard let live = windowsOf(rec.bundleID, onSpace: space) else { leftBehind += 1; continue }
                guard let match = live.windows.first(where: { $0.onSpace && ($0.1 == rec.wid || $0.title == rec.title) })
                                ?? live.windows.first(where: { $0.onSpace }) else {
                    leftBehind += 1 // window exists only on another space — macOS 26 blocks moving it
                    continue
                }
                if let minVal: NSNumber = axAttr(match.0, "AXMinimized"),
                   minVal.boolValue != rec.minimized {
                    AXUIElementSetAttributeValue(
                        match.0,
                        "AXMinimized" as CFString,
                        rec.minimized ? kCFBooleanTrue : kCFBooleanFalse
                    )
                }
                axSetFrame(match.0, rec.frame)
                placed += 1
            }
        }

        // return the user to their original desktop
        if let cur = originalCurrent {
            CGSManagedDisplaySetCurrentSpace(conn, cur.displayID as CFString, cur.managedID)
        }

        var msg = "Workspace restored: \(placed) windows placed"
        if launchedApps.count > 0 { msg += ", \(launchedApps.count) apps launched" }
        if leftBehind > 0 { msg += ". \(leftBehind) windows stayed on other desktops (macOS blocks moving them — drag them in Mission Control if needed)" }
        status(msg)
    }

    // MARK: Browser URL capture/recreate (AppleScript, best-effort)

    /// Per-window (bounds, tab URLs) via AppleScript. Bounds ride along so
    /// each script window can be matched to its CG window by geometry —
    /// script window order does not line up with CGWindowList order,
    /// especially across desktops.
    private func captureBrowserURLs(bundleID: String) -> ([(bounds: CGRect, urls: [String])], Bool) {
        let appName = bundleID.hasPrefix("com.google.Chrome") ? "Google Chrome" : "Safari"
        let script = """
        tell application "\(appName)"
            set out to {}
            repeat with w in windows
                set {l, t, r, b} to bounds of w
                set end of out to {l, t, r, b, (URL of every tab of w) as list}
            end repeat
            return out
        end
        """
        var result: [(bounds: CGRect, urls: [String])] = []
        guard let sc = NSAppleScript(source: script) else { return (result, false) }
        var err: NSDictionary?
        let desc = sc.executeAndReturnError(&err)
        if let err {
            // -1743 = not permitted (Automation consent missing/denied)
            let denied = (err[NSAppleScript.errorNumber] as? Int) == -1743
            return (result, denied)
        }
        guard desc.numberOfItems > 0 else { return (result, false) }
        for i in 1...desc.numberOfItems {
            guard let item = desc.atIndex(i), item.numberOfItems >= 5 else { continue }
            let l = CGFloat(item.atIndex(1)?.int32Value ?? 0)
            let t = CGFloat(item.atIndex(2)?.int32Value ?? 0)
            let r = CGFloat(item.atIndex(3)?.int32Value ?? 0)
            let b = CGFloat(item.atIndex(4)?.int32Value ?? 0)
            var urls: [String] = []
            if let urlsDesc = item.atIndex(5), urlsDesc.numberOfItems > 0 {
                for j in 1...urlsDesc.numberOfItems {
                    if let u = urlsDesc.atIndex(j)?.stringValue { urls.append(u) }
                }
            }
            result.append((CGRect(x: l, y: t, width: r - l, height: b - t), urls))
        }
        return (result, false)
    }

    /// Index of the script window whose bounds best match `frame` (within
    /// ~40pt total drift), so tab URLs attach to the right window.
    private static func closestBrowserWindow(_ candidates: [(bounds: CGRect, urls: [String])], to frame: CGRect) -> Int? {
        var best: (i: Int, d: CGFloat)?
        for (i, c) in candidates.enumerated() {
            let d = abs(c.bounds.minX - frame.minX) + abs(c.bounds.minY - frame.minY)
                + abs(c.bounds.width - frame.width) + abs(c.bounds.height - frame.height)
            if d < (best?.d ?? 40) { best = (i, d) }
        }
        return best?.i
    }

    private func createBrowserWindow(bundleID: String, urls: [String]) {
        let appName = bundleID.hasPrefix("com.google.Chrome") ? "Google Chrome" : "Safari"
        let first = appleScriptStringLiteral(urls[0])
        let rest = urls.dropFirst()
        let tabLines = rest.map { url in
            let literal = appleScriptStringLiteral(url)
            return "make new tab at end of tabs of front window with properties {URL:\(literal)}"
        }.joined(separator: "\n        ")
        let script = """
        tell application \(appleScriptStringLiteral(appName))
            activate
            make new window with properties {URL:\(first)}
            \(tabLines)
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err { NSLog("SpaceNamer browser recreate error: \(err)") }
    }
}
