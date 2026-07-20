import Cocoa
import SwiftUI

// MARK: - Panel data source

final class PanelModel: ObservableObject {
    @Published var spaces: [Space] = []
    @Published var liveApps: [String: [String]] = [:] // space uuid → open apps
    @Published var snapshotSummary: String?
    @Published var snapshotApps: [(spaceLabel: String, bundleIDs: [String])] = []
    @Published var snapshotDate: Date?

    var spacesProvider: (() -> [Space])?
    var liveAppsProvider: (() -> [String: [String]])?
    var snapshotInfoProvider: (() -> (date: Date?, summary: String?, apps: [(spaceLabel: String, bundleIDs: [String])]))?

    var onRename: ((String, String) -> Void)?
    var onSave: (() -> Void)?
    var onRestore: (() -> Void)?

    func reload() {
        if let spacesProvider { spaces = spacesProvider() }
        if let liveAppsProvider { liveApps = liveAppsProvider() }
        if let snapshotInfoProvider {
            let info = snapshotInfoProvider()
            snapshotDate = info.date
            snapshotSummary = info.summary
            snapshotApps = info.apps
        }
    }
}

// MARK: - Desktop row

struct DesktopRow: View {
    let space: Space
    let isCurrent: Bool
    let apps: [String]          // bundle IDs of apps open on this space
    let onRename: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @State private var hovering = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isCurrent ? Color.accentColor : Color.white.opacity(0.18))
                .frame(width: 6, height: 6)

            if editing {
                TextField("Name", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { onRename(draft); editing = false }
                    .onExitCommand { editing = false }
            } else {
                Text(space.displayName)
                    .font(.system(size: 12.5, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.85))
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    ForEach(Array(apps.prefix(5)), id: \.self) { bid in
                        AppIconView(bundleID: bid, size: 15)
                    }
                    if apps.count > 5 {
                        Text("+\(apps.count - 5)")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                }
                Button {
                    draft = space.customName ?? ""
                    editing = true
                    fieldFocused = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 1 : 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(hovering && !editing ? Color.white.opacity(0.10) : (isCurrent ? Color.accentColor.opacity(0.18) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !editing {
                draft = space.customName ?? ""
                editing = true
                fieldFocused = true
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(space.customName != nil ? space.defaultName : "Click to rename")
    }
}

// MARK: - Workspace dashboard card

struct WorkspaceCard: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
                Text("Workspace")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.5))
                Spacer()
                if let date = model.snapshotDate {
                    Text(date, style: .relative)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.35))
                }
            }

            if let summary = model.snapshotSummary {
                Text(summary)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                ForEach(model.snapshotApps, id: \.spaceLabel) { entry in
                    HStack(spacing: 8) {
                        Text(entry.spaceLabel)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.45))
                            .frame(width: 72, alignment: .leading)
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            ForEach(Array(entry.bundleIDs.prefix(8)), id: \.self) { bid in
                                AppIconView(bundleID: bid)
                            }
                            if entry.bundleIDs.count > 8 {
                                Text("+\(entry.bundleIDs.count - 8)")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.4))
                            }
                        }
                    }
                }

                HStack(spacing: 8) {
                    PanelButton(title: "Save", icon: "square.and.arrow.down", tint: .accentColor) {
                        model.onSave?()
                    }
                    PanelButton(title: "Restore", icon: "arrow.clockwise", tint: Color(red: 0.2, green: 0.65, blue: 0.35)) {
                        model.onRestore?()
                    }
                    Spacer()
                    Text("⌃⌥⌘S · ⌃⌥⌘R")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
            } else {
                Text("No layout saved yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
                PanelButton(title: "Save Current Layout", icon: "square.and.arrow.down", tint: .accentColor) {
                    model.onSave?()
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }
}

struct AppIconView: View {
    let bundleID: String
    var size: CGFloat = 18
    var body: some View {
        Group {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: size, height: size)
                    .foregroundStyle(Color.white.opacity(0.35))
            }
        }
        .help(bundleID)
    }
}

struct PanelButton: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 10.5, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(hovering ? 0.95 : 0.75)))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Root panel view

struct SpaceNamerPanel: View {
    @ObservedObject var model: PanelModel
    var overlayEnabled: Bool
    var loginEnabled: Bool
    var autoRestoreEnabled: Bool
    var onToggleOverlay: () -> Void
    var onToggleLogin: () -> Void
    var onToggleAutoRestore: () -> Void
    var onCheckUpdates: () -> Void
    var onOpenPrefs: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("SpaceNamer")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()
                if let current = model.spaces.first(where: { $0.isCurrent }) {
                    Text(current.displayName)
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.35)))
                        .foregroundStyle(.white)
                }
                Button(action: onOpenPrefs) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Edit all names")
            }

            // Desktops
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(model.spaces, id: \.uuid) { space in
                        DesktopRow(
                            space: space,
                            isCurrent: space.isCurrent,
                            apps: model.liveApps[space.uuid] ?? [],
                            onRename: { newName in model.onRename?(space.uuid, newName) }
                        )
                    }
                }
            }
            .frame(maxHeight: 250)

            WorkspaceCard(model: model)

            // Toggles
            VStack(spacing: 4) {
                PanelToggle(label: "Names in Mission Control", isOn: overlayEnabled, action: onToggleOverlay)
                PanelToggle(label: "Launch at Login", isOn: loginEnabled, action: onToggleLogin)
                PanelToggle(label: "Restore Workspace at Login", isOn: autoRestoreEnabled, action: onToggleAutoRestore)
            }

            Divider().background(Color.white.opacity(0.12))

            // Footer
            HStack {
                Button(action: onCheckUpdates) {
                    Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Button(action: onQuit) {
                    Label("Quit", systemImage: "power")
                        .font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.white.opacity(0.55))
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(Color(red: 0.11, green: 0.11, blue: 0.13))
    }
}

struct PanelToggle: View {
    let label: String
    let isOn: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : Color.white.opacity(0.4))
                    .font(.system(size: 12))
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.75))
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Panel window (custom borderless — no NSPopover chrome, no clipping)

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class PanelController: NSObject {
    let model = PanelModel()
    private var panel: NSPanel?
    private var outsideMonitor: Any?
    private var escapeMonitor: Any?
    private weak var statusItem: NSStatusItem?

    var overlayEnabledProvider: (() -> Bool) = { false }
    var loginEnabledProvider: (() -> Bool) = { false }
    var autoRestoreEnabledProvider: (() -> Bool) = { false }
    var onToggleOverlay: () -> Void = {}
    var onToggleLogin: () -> Void = {}
    var onToggleAutoRestore: () -> Void = {}
    var onCheckUpdates: () -> Void = {}
    var onOpenPrefs: () -> Void = {}
    var onQuit: () -> Void = {}

    func attach(to statusItem: NSStatusItem) {
        self.statusItem = statusItem
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp])
    }

    @objc private func toggle() {
        if let panel, panel.isVisible {
            close()
        } else {
            show()
        }
    }

    private func show() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        model.reload()

        let view = SpaceNamerPanel(
            model: model,
            overlayEnabled: overlayEnabledProvider(),
            loginEnabled: loginEnabledProvider(),
            autoRestoreEnabled: autoRestoreEnabledProvider(),
            onToggleOverlay: { [weak self] in self?.close(); self?.onToggleOverlay() },
            onToggleLogin: { [weak self] in self?.close(); self?.onToggleLogin() },
            onToggleAutoRestore: { [weak self] in self?.close(); self?.onToggleAutoRestore() },
            onCheckUpdates: { [weak self] in self?.close(); self?.onCheckUpdates() },
            onOpenPrefs: { [weak self] in self?.close(); self?.onOpenPrefs() },
            onQuit: { [weak self] in self?.close(); self?.onQuit() }
        )
        let hosting = NSHostingView(rootView: view)

        // Size to content, clamped to the visible screen — clipping is impossible.
        let width: CGFloat = 320
        hosting.frame.size = hosting.fittingSize
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let maxHeight = screen.visibleFrame.height - 20
        let height = min(hosting.fittingSize.height, maxHeight)

        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false

        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = 10
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting

        // Position anchored under the status item
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(buttonRectInWindow)
        var x = buttonScreenRect.midX - width / 2
        x = max(screen.visibleFrame.minX + 8, min(x, screen.visibleFrame.maxX - width - 8))
        let y = buttonScreenRect.minY - height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel

        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }
            return event
        }
    }

    func close() {
        panel?.close()
        panel = nil
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        outsideMonitor = nil
        escapeMonitor = nil
    }
}
