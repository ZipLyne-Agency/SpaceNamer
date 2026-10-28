import Cocoa
import Carbon
import ApplicationServices

// MARK: - Private SkyLight / CGS APIs

typealias CGSConnectionID = Int32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSCopyManagedDisplaySpaces")
func _CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> Unmanaged<CFArray>
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray {
    _CGSCopyManagedDisplaySpaces(cid).takeRetainedValue()
}

/// Switches a display to a given space directly — no Mission Control, no
/// Accessibility permission required.
@_silgen_name("CGSManagedDisplaySetCurrentSpace")
func CGSManagedDisplaySetCurrentSpace(_ cid: CGSConnectionID, _ display: CFString, _ space: CGSSpaceID)

// MARK: - Model

struct Space: Equatable {
    let uuid: String         // stable identity: survives reorders AND reboots (persisted in com.apple.spaces.plist)
    let managedID: CGSSpaceID // ephemeral id used for switching
    let displayID: String
    let displayIndex: Int
    let positionOnDisplay: Int
    /// 1-based among non-fullscreen spaces on this display — matches the
    /// native strip, which numbers only real desktops ("Desktop 1, Zed,
    /// Desktop 2"), skipping full-screen apps.
    let desktopNumber: Int
    let isFullScreen: Bool
    let isCurrent: Bool
    let fullScreenApp: String? // owning app's name for a full-screen space
    var customName: String?
    var defaultName: String {
        if isFullScreen { return fullScreenApp ?? "Full Screen" }
        return "Desktop \(desktopNumber)"
    }
    var displayName: String { customName ?? defaultName }

    static func == (a: Space, b: Space) -> Bool {
        a.uuid == b.uuid && a.managedID == b.managedID && a.displayID == b.displayID &&
        a.displayIndex == b.displayIndex &&
        a.positionOnDisplay == b.positionOnDisplay && a.desktopNumber == b.desktopNumber &&
        a.isFullScreen == b.isFullScreen && a.isCurrent == b.isCurrent &&
        a.fullScreenApp == b.fullScreenApp && a.customName == b.customName
    }
}

// MARK: - NameStore (keyed by space UUID so names survive reorders and reboots)

final class NameStore {
    private let key = "SpaceNames_v3"
    private let defaults = UserDefaults.standard
    private(set) var names: [String: String]

    init() {
        self.names = (defaults.dictionary(forKey: key) as? [String: String]) ?? [:]
    }

    func name(for uuid: String) -> String? {
        let trimmed = names[uuid]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func set(_ name: String, for uuid: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            names.removeValue(forKey: uuid)
        } else {
            names[uuid] = trimmed
        }
        defaults.set(names, forKey: key)
    }

    func reset() {
        names.removeAll()
        defaults.removeObject(forKey: key)
    }
}

// MARK: - SpaceObserver

protocol SpaceObserverDelegate: AnyObject {
    func spacesDidChange(_ spaces: [Space])
}

final class SpaceObserver {
    weak var delegate: SpaceObserverDelegate?
    private let conn = CGSMainConnectionID()
    private let store: NameStore
    private var lastSpaces: [Space] = []
    private var timer: Timer?

    /// Latest space list for UI consumers (panel).
    var currentSpacesSnapshot: [Space] { lastSpaces }

    init(store: NameStore) {
        self.store = store
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(refresh),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        // activeSpaceDidChangeNotification does not fire for space add/remove/reorder,
        // so poll on a slow timer and diff — CGSCopyManagedDisplaySpaces is cheap.
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    @objc func refresh() {
        guard let displays = CGSCopyManagedDisplaySpaces(conn) as? [[String: Any]] else { return }

        var all: [Space] = []

        // Sort displays deterministically so display index is stable
        let sortedDisplays = displays.sorted { a, b in
            let idA = a["Display Identifier"] as? String ?? ""
            let idB = b["Display Identifier"] as? String ?? ""
            return idA < idB
        }

        struct Raw {
            let uuid: String; let mid: CGSSpaceID; let displayID: String
            let displayIdx: Int; let pos: Int; let desktopNum: Int
            let isFullScreen: Bool; let isCurrent: Bool
        }
        var raws: [Raw] = []
        var missingFS: [CGSSpaceID: String] = [:] // fullscreen spaces w/o cached app name

        for (displayIdx, display) in sortedDisplays.enumerated() {
            guard let displayID = display["Display Identifier"] as? String,
                  let spacesArr = display["Spaces"] as? [[String: Any]] else { continue }
            let currentID = ((display["Current Space"] as? [String: Any])?["ManagedSpaceID"] as? NSNumber)?.uint64Value ?? 0

            var desktopCount = 0
            for (posOnDisplay, spaceInfo) in spacesArr.enumerated() {
                guard let idNum = spaceInfo["ManagedSpaceID"] as? NSNumber else { continue }
                let mid = idNum.uint64Value
                let uuid = spaceInfo["uuid"] as? String ?? "managed-\(mid)"
                let isFullScreen = spaceInfo["TileLayoutManager"] is [String: Any]
                if !isFullScreen { desktopCount += 1 }
                if isFullScreen, fsNameCache[uuid] == nil { missingFS[mid] = uuid }
                raws.append(Raw(uuid: uuid, mid: mid, displayID: displayID,
                                displayIdx: displayIdx, pos: posOnDisplay,
                                desktopNum: desktopCount, isFullScreen: isFullScreen,
                                isCurrent: mid == currentID))
            }
        }

        resolveFullScreenNames(missingFS)
        for r in raws {
            all.append(Space(
                uuid: r.uuid,
                managedID: r.mid,
                displayID: r.displayID,
                displayIndex: r.displayIdx,
                positionOnDisplay: r.pos,
                desktopNumber: r.desktopNum,
                isFullScreen: r.isFullScreen,
                isCurrent: r.isCurrent,
                fullScreenApp: r.isFullScreen ? fsNameCache[r.uuid] : nil,
                customName: store.name(for: r.uuid)
            ))
        }

        guard all != lastSpaces else { return }
        // Guard against transient garbage reads (e.g. mid-drag in Mission Control,
        // display reconfig): never accept an empty space list as truth.
        guard !all.isEmpty else { return }
        lastSpaces = all
        // NOTE: no name pruning here — a desktop briefly disappearing from the
        // CGS list (mid-drag, transitions) must never delete the user's names.
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.spacesDidChange(all)
        }
    }

    /// A full-screen space's native strip label is its app's name. Resolve it
    /// once per space by finding a window on that space (CGWindowList sees all
    /// spaces; owner name needs no permissions) and cache — the owning app of
    /// a full-screen space never changes for its lifetime.
    private var fsNameCache: [String: String] = [:] // space uuid → app name

    private func resolveFullScreenNames(_ wanted: [CGSSpaceID: String]) {
        guard !wanted.isEmpty,
              let winList = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return }
        var remaining = wanted
        for w in winList {
            if remaining.isEmpty { break }
            guard (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let widNum = w[kCGWindowNumber as String] as? NSNumber,
                  let owner = w[kCGWindowOwnerName as String] as? String, !owner.isEmpty,
                  let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  b.width > 200, b.height > 200 else { continue }
            guard let arr = SLSCopySpacesForWindows(conn, 0x7, [widNum] as CFArray) as? [NSNumber] else { continue }
            for sidNum in arr {
                if let uuid = remaining[sidNum.uint64Value] {
                    fsNameCache[uuid] = owner
                    remaining.removeValue(forKey: sidNum.uint64Value)
                }
            }
        }
    }

}

// MARK: - Mission Control Overlay
//
// Draws custom space names over the "Desktop N" label strip, only while
// Mission Control is open. No permissions needed: MC is detected via
// CGWindowList (Dock's fullscreen window), positions come from the CGS
// space list. The windows are transparent, click-through, and float above
// the MC window at .screenSaver level.

struct OverlayPill: Equatable {
    let text: String
    let isCurrent: Bool
    let center: CGPoint    // view coords, AppKit bottom-left origin
    let minCover: CGFloat  // native label extent underneath — never leave it peeking out
    let maxWidth: CGFloat  // cap so pills never cover a neighbor label
    var compact: Bool = false // collapsed strip on macOS 27: tighter, smaller type
}

/// One label chip, styled after Mission Control's own labels on macOS 27:
/// a rounded, blurred, translucent capsule with white medium text. The blur
/// smears the native label underneath and the tint hides what is left, so
/// the chip reads as the label itself rather than a sticker on top.
final class OverlayChip: NSView {
    private let blur = NSVisualEffectView()
    private let tint = NSView()
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)
        tint.wantsLayer = true
        label.alignment = .center
        label.lineBreakMode = .byClipping
        label.textColor = .white
        label.appearance = NSAppearance(named: .darkAqua)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        label.shadow = shadow
        addSubview(blur); addSubview(tint); addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ pill: OverlayPill) {
        let font = NSFont.systemFont(ofSize: pill.compact ? 12 : 13, weight: .medium)
        let pad: CGFloat = pill.compact ? 14 : 20
        var text = pill.text
        var size = (text as NSString).size(withAttributes: [.font: font])
        while text.count > 1, size.width > pill.maxWidth - pad {
            text = String(text.dropLast(text.hasSuffix("…") ? 2 : 1)) + "…"
            size = (text as NSString).size(withAttributes: [.font: font])
        }
        let w = min(max(size.width + pad, pill.minCover), max(pill.maxWidth, 40))
        let h: CGFloat = pill.compact ? 22 : 24
        frame = NSRect(x: (pill.center.x - w / 2).rounded(), y: (pill.center.y - h / 2).rounded(),
                       width: w.rounded(), height: h)
        blur.frame = bounds
        tint.frame = bounds
        tint.layer?.backgroundColor = pill.isCurrent
            ? NSColor(white: 1, alpha: 0.26).cgColor
            : NSColor(white: 0, alpha: 0.38).cgColor
        layer?.borderWidth = pill.isCurrent ? 0.5 : 0
        layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        label.font = font
        label.stringValue = text
        label.frame = NSRect(x: 0, y: (h - size.height) / 2 - 0.5, width: w, height: size.height)
    }
}

final class OverlayLabelView: NSView {
    private var chips: [OverlayChip] = []
    var pills: [OverlayPill] = [] {
        didSet {
            guard pills != oldValue else { return }
            while chips.count > pills.count { chips.removeLast().removeFromSuperview() }
            while chips.count < pills.count {
                let c = OverlayChip(frame: .zero)
                addSubview(c); chips.append(c)
            }
            for (c, p) in zip(chips, pills) { c.configure(p) }
            // Fade the whole set in when labels (re)appear, instead of popping.
            if oldValue.isEmpty, !pills.isEmpty {
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.18
                    animator().alphaValue = 1
                }
            }
        }
    }
}

final class MCOverlayController {
    private var windows: [NSScreen: (NSWindow, OverlayLabelView)] = [:]
    private var spaces: [Space] = []
    private var timer: Timer?
    private(set) var overlayVisible = false
    /// The MC spaces bar starts collapsed; it expands to thumbnails when the
    /// pointer enters the top strip. Our hardcoded geometry matches the
    /// *expanded* layout, so we latch expansion on pointer position
    /// (NSEvent.mouseLocation needs no permission) and stay shown until MC
    /// closes. Before the latch, pills can still show over the collapsed
    /// labels — at exact frames read from the Dock's AX tree (Accessibility
    /// only; without it the collapsed state stays blank as before).
    private var expanded = false
    /// Per-screen frames of the collapsed strip's space buttons (global
    /// AppKit coords, sorted left→right), or empty when AX is unavailable.
    private var collapsedRects: [NSScreen: [CGRect]] = [:]
    private var lastAXRead = Date.distantPast
    private var lastSpacesRefresh = Date.distantPast
    /// macOS 27+: Mission Control is drawn by WindowManager, whose "Spaces
    /// Bar" window tells us both that MC is open and whether the bar is
    /// expanded (its height changes). nil on older systems, where the
    /// Dock-owned MC window and the hover latch are used instead.
    private var spacesBar: SpacesBarWindow?
    /// Last few Spaces Bar heights (one per tick). The bar animates between
    /// its collapsed and expanded sizes; pills are only placed once it has
    /// held the same height for a few ticks, so they never chase the animation.
    private var barHeights: [CGFloat] = []
    private var barSettled = false
    /// Height of the Spaces Bar when it first appeared for this Mission
    /// Control session: collapsed (128) when opened normally, expanded (244)
    /// when the pointer was already at the top edge. Mission Control lays the
    /// thumbnails out differently in the two cases (see windowManagerPills).
    private var barFirstHeight: CGFloat?
    /// macOS 27: the native items of the Spaces Bar read from WindowManager's
    /// AX tree (centre x and label text), when Accessibility is granted.
    private var axItems: [SpacesBarItem]? = nil
    /// Called at most every 0.3s while the overlay is visible — re-reads the
    /// CGS space list so pills track reorders quickly.
    var onTick: (() -> Void)?

    private let idleInterval: TimeInterval = 0.2  // waiting for MC to open
    private let activeInterval: TimeInterval = 0.1 // MC open: hover latch + layout

    /// Geometry measured from Mission Control on macOS 26 (fractions of screen size,
    /// verified programmatically against live captures at 11 desktops): the expanded
    /// bar's row is centered as a group (minus ~0.1% width for the + button);
    /// per-item spacing 8.54% of width at N=11; label strip center 11.6% from top.
    private let labelYFraction: CGFloat = 0.116

    private func expandedDx(_ n: Int) -> CGFloat {
        // measured live: N=10 → 0.0925, N=11 → 0.0854 — both fit dx ≈ 0.94/N almost exactly
        // (the bar spans ~94% of screen width when space is tight). Cap for small N so
        // wide/ultrawide screens with few desktops don't over-space.
        return min(0.94 / CGFloat(max(n, 1)), 0.12)
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "MCOverlayEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "MCOverlayEnabled") }
    }

    func start() {
        schedule(idleInterval)
        // The Dock announces Mission Control activation the moment it starts —
        // reacting to it makes the overlay near-instant. The poll stays as the
        // fallback open-detector and the only close-detector (there is no
        // "asleep" counterpart notification).
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.expose.awake"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.pokeSoon() }
    }

    private func schedule(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = interval * 0.2
    }

    /// Burst of quick checks right after the Dock announces Mission Control —
    /// the MC window can lag the notification by a frame or two.
    private func pokeSoon() {
        tick()
        for delay in [0.05, 0.15, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, !self.overlayVisible else { return }
                self.tick()
            }
        }
    }

    func update(spaces: [Space]) {
        self.spaces = spaces
        if overlayVisible { layout() }
    }

    private func tick() {
        let bar = isEnabled ? Self.spacesBarWindow() : nil
        let open = isEnabled && (bar != nil || Self.missionControlIsOpen())
        if open && !overlayVisible {
            overlayVisible = true
            expanded = false
            collapsedRects = [:]
            lastAXRead = .distantPast
            schedule(activeInterval)
            show()
        } else if !open && overlayVisible {
            overlayVisible = false
            expanded = false
            spacesBar = nil
            barHeights = []
            barSettled = false
            barFirstHeight = nil
            axItems = nil
            collapsedRects = [:]
            schedule(idleInterval)
            hide()
        }
        guard overlayVisible else { return }

        spacesBar = bar
        if let bar {
            // macOS 27+: the bar's own height says whether it is expanded
            // (measured: 128pt collapsed, 244pt with thumbnails), so no
            // hover latch and no AX read are needed.
            expanded = bar.height > 180
            if barFirstHeight == nil { barFirstHeight = bar.height }
            barHeights.append(bar.height)
            if barHeights.count > 3 { barHeights.removeFirst() }
            barSettled = barHeights.count == 3 && barHeights.allSatisfy { $0 == bar.height }
            if barSettled, Date().timeIntervalSince(lastAXRead) > 0.25 {
                axItems = Self.spacesBarAXItems()
                lastAXRead = Date()
            }
        } else {
            barSettled = true
            // Latch bar expansion: pointer entering the compact strip (~top 36pt)
            // expands it to thumbnails. Matching Dock's hover zone keeps the
            // hardcoded-geometry pills hidden whenever the bar isn't expanded.
            if !expanded {
                let mouse = NSEvent.mouseLocation
                if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
                   mouse.y > screen.frame.maxY - 36 {
                    expanded = true
                }
            }

            // Collapsed-state geometry from the Dock's AX tree; re-read sparingly —
            // the strip is static while collapsed (reorders require expanding it).
            if !expanded, Date().timeIntervalSince(lastAXRead) > 0.25 {
                collapsedRects = Self.collapsedLabelRects() ?? [:]
                lastAXRead = Date()
            }
        }

        if Date().timeIntervalSince(lastSpacesRefresh) > 0.3 {
            lastSpacesRefresh = Date()
            onTick?() // refresh CGS spaces (fast reorder tracking)
        }
        layout() // keep positions fresh while MC is open (reorder, rename, expansion)
    }

    // MARK: Collapsed-strip geometry via the Dock's AX tree (optional)
    //
    // With Accessibility granted (the workspace feature already asks for it),
    // the Dock exposes Mission Control's spaces bar as AX buttons — including
    // in the collapsed state, where our hardcoded expanded geometry doesn't
    // apply. This lets pills appear immediately, before any hover.

    private static func axAttr<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
        return ref as? T
    }

    private static func axChildren(_ el: AXUIElement) -> [AXUIElement] {
        axAttr(el, kAXChildrenAttribute as String) ?? []
    }

    private static func axFrame(_ el: AXUIElement) -> CGRect? {
        guard let posRef: AXValue = axAttr(el, kAXPositionAttribute as String),
              let sizeRef: AXValue = axAttr(el, kAXSizeAttribute as String) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(posRef, .cgPoint, &p),
              AXValueGetValue(sizeRef, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Frames of the collapsed strip's space buttons (global AppKit coords,
    /// sorted left→right), bucketed per screen. nil without Accessibility or
    /// when the strip isn't found — callers fall back to hover-only behavior.
    private static func collapsedLabelRects() -> [NSScreen: [CGRect]]? {
        guard WorkspaceEngine.accessibilityTrusted(prompt: false) else { return nil }
        guard let dock = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else { return nil }
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryMaxY = primary.frame.maxY

        // Mission Control lives in top-level Dock groups; the dock's icon row
        // is an AXList — skip it rather than walking hundreds of items.
        let dockApp = AXUIElementCreateApplication(dock.processIdentifier)
        var queue = axChildren(dockApp).filter { el in
            let role: String? = axAttr(el, kAXRoleAttribute as String)
            return role != "AXList"
        }

        var found: [NSScreen: [CGRect]] = [:]
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let el = queue.removeFirst()
            visited += 1
            let role: String? = axAttr(el, kAXRoleAttribute as String)
            guard role == "AXButton" else {
                queue.append(contentsOf: axChildren(el))
                continue
            }
            guard let f = axFrame(el) else { continue }
            // AX coords are top-left-origin globals; flip to AppKit bottom-left.
            let rect = CGRect(x: f.origin.x, y: primaryMaxY - f.origin.y - f.height,
                              width: f.width, height: f.height)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            // Collapsed strip buttons: short, hugging the top edge of a screen.
            // (Expanded thumbnails are tall — height filters them out, so a
            // stale read during the expand animation can't misplace pills.)
            guard rect.height < 50,
                  let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) }),
                  screen.frame.maxY - center.y < 120 else { continue }
            // Skip the "+" (add desktop) button at the strip's right edge.
            if rect.width < 40, center.x > screen.frame.minX + screen.frame.width * 0.9 { continue }
            found[screen, default: []].append(rect)
        }
        guard !found.isEmpty else { return nil }
        for (screen, rects) in found {
            found[screen] = rects.sorted { $0.midX < $1.midX }
        }
        return found
    }

    /// Mission Control's spaces bar as seen in the on-screen window list.
    /// `frame` is in CG coordinates (top-left origin, global).
    struct SpacesBarWindow {
        let frame: CGRect
        var height: CGFloat { frame.height }
    }

    /// macOS 27+: Mission Control belongs to the WindowManager process, which
    /// puts a "Spaces Bar" window on screen (layer 14, full screen width,
    /// hugging the top edge) for the strip and an "ExposeShieldWindow"
    /// (layer 19, full screen) behind the thumbnails. Both vanish the instant
    /// MC closes. Verified on macOS 27.0.1 (26A434): collapsed bar 128pt
    /// high, expanded (thumbnails) 244pt.
    ///
    /// Window *names* are deliberately not used: `kCGWindowName` of other
    /// processes is only filled in with Screen Recording permission, which
    /// SpaceNamer does not ask for. Owner name, layer and bounds are enough.
    static func spacesBarWindow() -> SpacesBarWindow? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        guard let primary = NSScreen.screens.first else { return nil }
        for w in list {
            guard (w[kCGWindowOwnerName as String] as? String) == "WindowManager",
                  (w[kCGWindowLayer as String] as? Int) == 14,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
                  let width = b["Width"] as? CGFloat, let height = b["Height"] as? CGFloat,
                  height > 60, height < 500
            else { continue }
            // Full width of the screen it sits on, flush with that screen's top.
            let screen = NSScreen.screens.first { s in
                let top = primary.frame.maxY - s.frame.maxY // CG y of this screen's top
                return abs(s.frame.origin.x - x) < 2 && abs(top - y) < 2
            }
            guard let screen, abs(screen.frame.width - width) < 2 else { continue }
            return SpacesBarWindow(frame: CGRect(x: x, y: y, width: width, height: height))
        }
        return nil
    }

    /// Legacy detector (macOS 26 and earlier): Mission Control is a
    /// full-screen window owned by the Dock at layer 20.
    ///
    /// Not used on macOS 27+: there the Dock keeps a permanent full-screen
    /// window at layer 20 (the desktop/widgets layer) whether or not MC is
    /// open, so this check is always true. Matching it made the overlay stick
    /// on screen for good, with pills landing over ordinary windows as soon
    /// as the pointer touched the menu bar. MC is drawn by WindowManager on
    /// those systems and is found through `spacesBarWindow()` instead.
    static func missionControlIsOpen() -> Bool {
        if #available(macOS 27, *) { return false }
        guard let dock = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.dock"
        }) else { return false }
        let dockPID = dock.processIdentifier
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        return list.contains { w in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == dockPID,
                  (w[kCGWindowLayer as String] as? Int) == 20,
                  let b = w[kCGWindowBounds as String] as? [String: Any],
                  let width = b["Width"] as? CGFloat,
                  let height = b["Height"] as? CGFloat
            else { return false }
            // fullscreen-ish window owned by Dock = Mission Control
            return width > 1000 && height > 700
        }
    }

    private func screen(for displayID: String) -> NSScreen? {
        let screens = NSScreen.screens
        if screens.count <= 1 { return screens.first }
        if displayID == "Main" { return screens.first } // primary has zero origin
        for s in screens {
            if let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
               let uuid = CGDisplayCreateUUIDFromDisplayID(num)?.takeRetainedValue(),
               let str = CFUUIDCreateString(nil, uuid) as String?,
               str.caseInsensitiveCompare(displayID) == .orderedSame {
                return s
            }
        }
        return screens.first
    }

    private func show() {
        for screen in NSScreen.screens {
            if windows[screen] == nil {
                let w = NSWindow(
                    contentRect: screen.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                w.isOpaque = false
                w.backgroundColor = .clear
                w.ignoresMouseEvents = true
                w.hasShadow = false
                w.level = .screenSaver
                w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
                let v = OverlayLabelView(frame: NSRect(origin: .zero, size: screen.frame.size))
                w.contentView = v
                w.setFrameOrigin(screen.frame.origin)
                windows[screen] = (w, v)
            }
            windows[screen]?.0.orderFrontRegardless()
        }
        layout()
    }

    private func hide() {
        for (_, pair) in windows { pair.0.orderOut(nil) }
    }

    private func layout() {
        for (screen, pair) in windows {
            let (w, v) = pair
            w.setFrame(screen.frame, display: false)
            v.frame = NSRect(origin: .zero, size: screen.frame.size)

            // Match this screen to its CGS display's spaces
            let displaySpaces: [Space]
            if let matched = screenID(for: screen), let first = spaces.first(where: { $0.displayID == matched }) {
                displaySpaces = spaces.filter { $0.displayID == first.displayID }
            } else {
                // single display or no match: use spaces of the primary display group
                displaySpaces = spaces.filter { $0.displayIndex == 0 }
            }
            let ordered = displaySpaces.sorted { $0.positionOnDisplay < $1.positionOnDisplay }
            let named = ordered.filter { $0.customName != nil }

            if let bar = spacesBar {
                guard barSettled else { v.pills = []; continue }
                v.pills = Self.windowManagerPills(bar: bar, screen: screen, ordered: ordered,
                                                  named: named, expanded: expanded,
                                                  expandedFromHover: expanded && (barFirstHeight ?? 0) < 180,
                                                  axItems: axItems)
                continue
            }

            guard expanded else {
                // Bar still collapsed (no hover yet): cover each native
                // "Desktop N" label with a pill at its exact AX frame.
                // Counts must match 1:1 or we can't trust the mapping — then
                // (and without Accessibility) draw nothing, as before.
                if let rects = collapsedRects[screen], rects.count == ordered.count {
                    let gap = zip(rects.dropFirst(), rects).map { $0.midX - $1.midX }.min() ?? 200
                    var out: [OverlayPill] = []
                    for s in named {
                        guard let i = ordered.firstIndex(where: { $0.uuid == s.uuid }) else { continue }
                        let c = CGPoint(x: rects[i].midX - screen.frame.origin.x,
                                        y: rects[i].midY - screen.frame.origin.y)
                        out.append(OverlayPill(text: s.customName!, isCurrent: s.isCurrent,
                                               center: c, minCover: rects[i].width + 4,
                                               maxWidth: max(gap - 6, 48)))
                    }
                    v.pills = out
                } else {
                    v.pills = []
                }
                continue
            }

            let W = screen.frame.width
            let H = screen.frame.height
            let n = ordered.count

            let dx = expandedDx(n) * W
            let x0 = (W - CGFloat(n - 1) * dx) / 2
            // Nudged up a few points: sitting exactly on the measured center
            // leaves the pill grazing the strip's bottom separator line.
            let labelY = H * (1 - labelYFraction) + 5 // AppKit bottom-left origin

            // What macOS draws under our pill is the native label — its text
            // (defaultName mirrors it, incl. full-screen app names) plus the
            // wide padding of its own translucent pill. Cover the whole thing
            // so no native pixels peek out the sides.
            let nativeFont = NSFont.systemFont(ofSize: 13)
            var out: [OverlayPill] = []
            for s in named {
                guard let i = ordered.firstIndex(where: { $0.uuid == s.uuid }) else { continue }
                let nativeW = (ordered[i].defaultName as NSString)
                    .size(withAttributes: [.font: nativeFont]).width + 44
                out.append(OverlayPill(text: s.customName!, isCurrent: s.isCurrent,
                                       center: CGPoint(x: x0 + CGFloat(i) * dx, y: labelY),
                                       minCover: nativeW, maxWidth: .greatestFiniteMagnitude))
            }
            v.pills = out
        }
    }

    // MARK: macOS 27+ geometry (WindowManager's Spaces Bar)
    //
    // Measured on macOS 27.0.1, 1728×1117pt built-in display, 6 desktops,
    // from screen captures with and without hover:
    //  - collapsed bar (window 128pt high): "Desktop N" labels sit on one
    //    row centred at 52pt from the top of the screen, each label as wide
    //    as its text plus ~22pt, with ~8pt between labels, the whole row
    //    centred on the screen (the + button is outside the row).
    //  - expanded bar (window 244pt high): thumbnails 93pt high (149pt wide
    //    on this aspect ratio) spaced 170pt apart, labels centred 71pt above
    //    the bottom of the bar; the row is centred on the screen when the bar
    //    opens expanded, and shifted half a slot left when it expands from a
    //    hover over the collapsed strip.
    // Other desktop counts are extrapolated (the row shrinks to fit).
    // The native label text is the Dock's localized "Desktop %@" ("Bureau 3"
    // in French), which is what the pill has to cover.
    /// The text Mission Control itself draws under a space: the Dock's
    /// localized "Desktop %@" for a desktop, the app name for a full-screen
    /// space. Falls back to the English `defaultName`.
    private static let desktopFormat: String = {
        // `localizedString(forKey:)` on another app's bundle follows *this*
        // app's localization (English), not the user's language, so the
        // matching .lproj is picked by hand from the user's language list.
        let fallback = "Desktop %@"
        guard let dock = Bundle(path: "/System/Library/CoreServices/Dock.app") else { return fallback }
        let locs = Bundle.preferredLocalizations(from: dock.localizations,
                                                 forPreferences: Locale.preferredLanguages)
        for loc in locs + ["en", "Base"] {
            guard let path = dock.path(forResource: "Localizable", ofType: "strings",
                                       inDirectory: nil, forLocalization: loc),
                  let dict = NSDictionary(contentsOfFile: path),
                  let f = dict["DesktopNum"] as? String, f.contains("%@")
            else { continue }
            return f
        }
        return fallback
    }()

    struct SpacesBarItem { let x: CGFloat; let title: String }

    /// macOS 27+: with Accessibility granted, WindowManager exposes the
    /// Spaces Bar as an AXGroup titled "Spaces Bar" holding an AXList with
    /// one AXButton per space (title = the native label, e.g. "Bureau 3";
    /// description "exit to …") plus the "add desktop" button. The buttons'
    /// AXPosition.x is the item's centre in both the collapsed and the
    /// expanded layout (checked against screen captures: 660, 740, 821…
    /// collapsed; 435, 607, 778… expanded on a 1728pt-wide screen). Their
    /// reported size (169×129) and y do not follow the layout, so only x and
    /// the title are used. Returns nil without Accessibility or when the bar
    /// is not in the tree, and the caller falls back to measured geometry.
    private static func spacesBarAXItems() -> [SpacesBarItem]? {
        guard WorkspaceEngine.accessibilityTrusted(prompt: false),
              let wm = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == "com.apple.WindowManager" || $0.localizedName == "WindowManager"
              }) else { return nil }
        var queue = axChildren(AXUIElementCreateApplication(wm.processIdentifier))
        var visited = 0
        while !queue.isEmpty, visited < 200 {
            let el = queue.removeFirst()
            visited += 1
            let role: String? = axAttr(el, kAXRoleAttribute as String)
            guard role == "AXGroup" else { continue }
            let title: String? = axAttr(el, kAXTitleAttribute as String)
            guard title == "Spaces Bar" else { queue.append(contentsOf: axChildren(el)); continue }
            var items: [SpacesBarItem] = []
            for list in axChildren(el) {
                for b in axChildren(list) {
                    let r: String? = axAttr(b, kAXRoleAttribute as String)
                    let t: String? = axAttr(b, kAXTitleAttribute as String)
                    guard r == "AXButton", let t, !t.isEmpty, let f = axFrame(b) else { continue }
                    items.append(SpacesBarItem(x: f.origin.x, title: t))
                }
            }
            return items.isEmpty ? nil : items.sorted { $0.x < $1.x }
        }
        return nil
    }

    private static func nativeLabel(_ s: Space) -> String {
        if s.isFullScreen { return s.defaultName }
        return desktopFormat.replacingOccurrences(of: "%@", with: String(s.desktopNumber))
    }

    private static func windowManagerPills(bar: SpacesBarWindow, screen: NSScreen,
                                           ordered: [Space], named: [Space],
                                           expanded: Bool, expandedFromHover: Bool,
                                           axItems: [SpacesBarItem]?) -> [OverlayPill] {
        // The bar lives on one screen; draw nothing on the others.
        guard let primary = NSScreen.screens.first else { return [] }
        let cgTop = primary.frame.maxY - screen.frame.maxY
        guard abs(bar.frame.origin.y - cgTop) < 2,
              abs(bar.frame.origin.x - screen.frame.origin.x) < 2 else { return [] }

        let W = screen.frame.width
        let H = screen.frame.height
        let n = ordered.count
        guard n > 0 else { return [] }
        let font = NSFont.systemFont(ofSize: 13)
        func textWidth(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }
        var out: [OverlayPill] = []
        let yCollapsed = H - bar.height * (52.0 / 128.0)
        let yExpanded = H - (bar.height - 71)

        // Exact positions from the AX tree whenever it lists one item per
        // space on this display; everything below is the fallback.
        if let items = axItems, items.count == n {
            let xs = items.map { $0.x - screen.frame.origin.x }
            let spacing = zip(xs.dropFirst(), xs).map { $0 - $1 }.min() ?? 200
            for s in named {
                guard let i = ordered.firstIndex(where: { $0.uuid == s.uuid }) else { continue }
                let nativeW = textWidth(items[i].title) + (expanded ? 30 : 22)
                out.append(OverlayPill(text: s.customName!, isCurrent: s.isCurrent,
                                       center: CGPoint(x: xs[i], y: expanded ? yExpanded : yCollapsed),
                                       minCover: min(nativeW, spacing - 6), maxWidth: spacing - 6,
                                       compact: !expanded))
            }
            return out
        }

        if !expanded {
            let widths = ordered.map { textWidth(nativeLabel($0)) + 22 }
            let gap: CGFloat = 8
            let rowW = widths.reduce(0, +) + gap * CGFloat(n - 1)
            var x = (W - rowW) / 2
            let y = yCollapsed
            var centers: [CGFloat] = []
            for wdt in widths { centers.append(x + wdt / 2); x += wdt + gap }
            for s in named {
                guard let i = ordered.firstIndex(where: { $0.uuid == s.uuid }) else { continue }
                out.append(OverlayPill(text: s.customName!, isCurrent: s.isCurrent,
                                       center: CGPoint(x: centers[i], y: y),
                                       minCover: widths[i] + 2, maxWidth: widths[i] + gap - 2,
                                       compact: true))
            }
            return out
        }

        var thumbW = 93 * (W / H) + 5
        var dx = thumbW + 21
        let available = W * 0.9
        if CGFloat(n) * dx > available {
            let k = available / (CGFloat(n) * dx)
            thumbW *= k; dx *= k
        }
        // Measured: when Mission Control opens with the pointer already at the
        // top edge, the thumbnails row is centred (6 desktops: centres at
        // 436, 607, …); when the bar expands later because the pointer
        // entered the collapsed strip, the whole row sits half a slot
        // further left (350, 521, …), as if laid out for one more item.
        var x0 = (W - CGFloat(n - 1) * dx) / 2
        if expandedFromHover { x0 -= dx / 2 }
        let y = yExpanded
        for s in named {
            guard let i = ordered.firstIndex(where: { $0.uuid == s.uuid }) else { continue }
            let nativeW = textWidth(nativeLabel(ordered[i])) + 30
            out.append(OverlayPill(text: s.customName!, isCurrent: s.isCurrent,
                                   center: CGPoint(x: x0 + CGFloat(i) * dx, y: y),
                                   minCover: min(nativeW, dx - 8), maxWidth: dx - 8))
        }
        return out
    }

    private func screenID(for screen: NSScreen) -> String? {
        let screens = NSScreen.screens
        if screens.count <= 1 { return spaces.first?.displayID }
        if screen == screens.first { return "Main" }
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(num)?.takeRetainedValue(),
              let str = CFUUIDCreateString(nil, uuid) as String? else { return nil }
        return str
    }
}

// MARK: - Preferences Window

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private let store: NameStore
    private var spaces: [Space] = []
    private var stack: NSStackView!
    private var onUpdate: (() -> Void)?

    init(store: NameStore, onUpdate: @escaping () -> Void) {
        self.store = store
        self.onUpdate = onUpdate

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "SpaceNamer — Rename Spaces"
        w.isReleasedWhenClosed = false
        w.center()

        super.init(window: w)
        w.delegate = self
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let header = NSTextField(labelWithString: "Type a custom name for each space. Leave blank to use the default. Names stick to their desktop even when you reorder spaces in Mission Control.")
        header.font = .systemFont(ofSize: 12)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byWordWrapping
        header.maximumNumberOfLines = 3
        header.translatesAutoresizingMaskIntoConstraints = false

        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.drawsBackground = false

        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -4),
        ])

        let reset = NSButton(title: "Reset All Names", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        close.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(header)
        content.addSubview(scroll)
        content.addSubview(reset)
        content.addSubview(close)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: reset.topAnchor, constant: -14),

            reset.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            reset.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),

            close.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
    }

    func update(with spaces: [Space]) {
        // Don't rebuild while the user is typing — the refresh poll would
        // otherwise recreate the text field mid-edit and drop focus.
        if window?.firstResponder is NSTextView { return }
        self.spaces = spaces
        rebuildRows()
    }

    private func rebuildRows() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }

        for space in spaces {
            let row = makeRow(for: space)
            stack.addArrangedSubview(row)
            row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -8).isActive = true
        }
    }

    private func makeRow(for space: Space) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = space.isCurrent
            ? NSColor.controlAccentColor.cgColor
            : NSColor.quaternaryLabelColor.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        let caption = NSTextField(labelWithString: space.defaultName + (space.isCurrent ? " (current)" : ""))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = space.isCurrent ? .controlAccentColor : .secondaryLabelColor
        caption.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField()
        field.stringValue = space.customName ?? ""
        field.placeholderString = space.defaultName
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 13)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.identifier = NSUserInterfaceItemIdentifier(rawValue: space.uuid)
        field.delegate = self

        row.addSubview(dot)
        row.addSubview(caption)
        row.addSubview(field)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            caption.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            caption.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            caption.widthAnchor.constraint(equalToConstant: 130),

            field.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 24),

            row.heightAnchor.constraint(equalToConstant: 32),
        ])

        return row
    }

    @objc private func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all custom space names?"
        alert.informativeText = "This removes every name you've set."
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            store.reset()
            onUpdate?()
        }
    }

    @objc private func closeWindow() {
        window?.close()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

extension PreferencesWindowController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let uuid = field.identifier?.rawValue else { return }
        store.set(field.stringValue, for: uuid)
        onUpdate?()
    }
}

// MARK: - Launch at login (LaunchAgent — works with ad-hoc signing, unlike SMAppService)

enum LoginItem {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.isaac.spacenamer.plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            let exe = Bundle.main.executablePath ?? ""
            let plist: [String: Any] = [
                "Label": "com.isaac.spacenamer",
                "ProgramArguments": [exe],
                "RunAtLoad": true,
            ]
            try? FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: plistURL, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}

// MARK: - Global hotkeys (Carbon — works without any permissions)

private var hotkeyActions: [UInt32: () -> Void] = [:]

private func hotkeyHandler(_ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    if let action = hotkeyActions[hotKeyID.id] { DispatchQueue.main.async { action() } }
    return noErr
}

enum Hotkeys {
    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotkeyHandler, 1, &spec, nil, nil)
    }

    static func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        hotkeyActions[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5350_4E52), id: id) // 'SPNR'
        RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = NameStore()
    private lazy var observer = SpaceObserver(store: store)
    private var statusItem: NSStatusItem!
    private var currentSpaces: [Space] = []
    private lazy var prefsWindow = PreferencesWindowController(store: store) { [weak self] in
        self?.observer.refresh()
    }
    private let overlay = MCOverlayController()
    private let workspace = WorkspaceEngine()
    private let updates = UpdateController()
    private let panel = PanelController()
    private var statusFlashTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.font = NSFont.menuBarFont(ofSize: 0)
        statusItem.button?.title = "Spaces"

        panel.model.spacesProvider = { [weak self] in self?.currentSpaces ?? [] }
        panel.model.snapshotInfoProvider = { [weak self] in
            guard let info = self?.workspace.snapshotInfo() else { return (nil, nil, []) }
            let desktops = info.perDesktop.count
            return (info.date,
                    "\(info.windowCount) windows · \(info.appCount) apps · \(desktops) desktop\(desktops == 1 ? "" : "s")",
                    info.perDesktop)
        }
        panel.model.liveAppsProvider = { [weak self] in
            guard let self else { return [:] }
            return self.workspace.liveApps(spaces: self.currentSpaces)
        }
        panel.model.onRename = { [weak self] uuid, name in
            self?.store.set(name, for: uuid)
            self?.observer.refresh()
        }
        panel.model.onSave = { [weak self] in self?.saveLayout() }
        panel.model.onRestore = { [weak self] in self?.restoreLayout() }
        panel.onOpenPrefs = { [weak self] in self?.openPrefs() }
        panel.overlayEnabledProvider = { [weak self] in self?.overlay.isEnabled ?? true }
        panel.loginEnabledProvider = { LoginItem.isEnabled }
        panel.autoRestoreEnabledProvider = { [weak self] in self?.workspace.restoreAtLogin ?? false }
        panel.onToggleOverlay = { [weak self] in self?.toggleOverlay() }
        panel.onToggleLogin = { [weak self] in self?.toggleLogin() }
        panel.onToggleAutoRestore = { [weak self] in self?.toggleAutoRestore() }
        panel.onCheckUpdates = { [weak self] in self?.checkForUpdates() }
        panel.onQuit = { NSApp.terminate(nil) }
        panel.attach(to: statusItem)

        observer.delegate = self
        observer.refresh()
        overlay.start()
        overlay.onTick = { [weak self] in self?.observer.refresh() }
        setupHotkeys()

        // Auto-restore workspace at login if enabled
        if workspace.restoreAtLogin && workspace.snapshotExists {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, WorkspaceEngine.accessibilityTrusted(prompt: false) else { return }
                self.flashStatus("Restoring…", seconds: 30)
                self.workspace.restore(currentSpaces: { [weak self] in self?.currentSpaces ?? [] }) { [weak self] msg in
                    DispatchQueue.main.async { self?.flashStatus(msg, seconds: 5) }
                }
            }
        }
    }

    private func setupHotkeys() {
        Hotkeys.install()
        let mods = UInt32(cmdKey | optionKey | controlKey)
        Hotkeys.register(id: 1, keyCode: UInt32(kVK_ANSI_S), modifiers: mods) { [weak self] in self?.saveLayout() }
        Hotkeys.register(id: 2, keyCode: UInt32(kVK_ANSI_R), modifiers: mods) { [weak self] in self?.restoreLayout() }
    }

    private func updateStatusTitle() {
        let name = currentSpaces.first(where: { $0.isCurrent })?.displayName ?? "Spaces"
        statusItem?.button?.title = name
    }
}

extension AppDelegate: SpaceObserverDelegate {
    func spacesDidChange(_ spaces: [Space]) {
        self.currentSpaces = spaces
        updateStatusTitle()
        prefsWindow.update(with: spaces)
        overlay.update(spaces: spaces)
        panel.model.reload()
    }
}

extension AppDelegate {
    @objc private func openPrefs() {
        prefsWindow.show()
    }

    @objc private func toggleLogin() {
        LoginItem.setEnabled(!LoginItem.isEnabled)
    }

    @objc private func toggleOverlay() {
        overlay.isEnabled = !overlay.isEnabled
    }

    @objc private func checkForUpdates() {
        updates.checkForUpdates()
    }

    @objc private func toggleAutoRestore() {
        workspace.restoreAtLogin = !workspace.restoreAtLogin
    }

    @objc private func saveLayout() {
        guard ensureAX() else { return }
        let result = workspace.capture(spaces: currentSpaces)
        if let error = result.errorMessage {
            flashStatus("Workspace save failed", seconds: 6)
            notify("Workspace was not saved", "SpaceNamer could not write \(result.path). \(error)")
            return
        }
        if result.browserURLsDenied {
            flashStatus("Saved \(result.windowCount) windows ✓ (browser URLs skipped — approve Automation)", seconds: 6)
            notify("Browser tab URLs skipped", "macOS blocked reading Chrome/Safari tab URLs. When the system asks whether SpaceNamer may control Chrome/Safari, choose Allow — or enable it in System Settings → Privacy & Security → Automation → SpaceNamer, then save again.")
        } else {
            flashStatus("Saved \(result.windowCount) windows ✓")
        }
    }

    @objc private func restoreLayout() {
        guard ensureAX() else { return }
        guard workspace.snapshotExists else {
            notify("No saved workspace", "Use “Save Layout as Workspace” (⌃⌥⌘S) first.")
            return
        }
        flashStatus("Restoring…", seconds: 30)
        workspace.restore(currentSpaces: { [weak self] in self?.currentSpaces ?? [] }) { [weak self] msg in
            DispatchQueue.main.async { self?.flashStatus(msg, seconds: 5) }
        }
    }

    private func flashStatus(_ text: String, seconds: Double = 3) {
        statusFlashTimer?.invalidate()
        statusItem?.button?.title = text
        statusFlashTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.updateStatusTitle()
        }
    }

    private func ensureAX() -> Bool {
        if WorkspaceEngine.accessibilityTrusted(prompt: false) { return true }
        _ = WorkspaceEngine.accessibilityTrusted(prompt: true)
        let alert = NSAlert()
        alert.messageText = "SpaceNamer needs Accessibility permission"
        alert.informativeText = """
        Saving and restoring workspaces requires moving and resizing other apps' windows.

        In System Settings → Privacy & Security → Accessibility, enable the toggle next to SpaceNamer (it should be listed now), then quit and relaunch SpaceNamer.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    private func notify(_ title: String, _ msg: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = msg
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

// MARK: - Entry

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
