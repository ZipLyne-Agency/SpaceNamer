# SpaceNamer

A beautiful menu bar app to name your macOS Spaces (virtual desktops) — your
names show **in Mission Control** on the desktop strip, and the popover panel
puts everything one click away: desktop cards with inline renaming and
one-tap switching, a workspace dashboard of your saved layout (per-desktop
app icons), and layout save/restore with global hotkeys (⌃⌥⌘S / ⌃⌥⌘R).
Names are keyed by each space's **UUID**, so they stick to their desktop
through reorders in Mission Control and across reboots.

Official builds are signed with Developer ID (ZipLyne LLC), use the hardened
runtime, are notarized and stapled by Apple, and update through a signed Sparkle
feed in this repository.

## Requirements

- macOS 14 or newer on Apple Silicon
- Xcode command-line tools
- No Accessibility permission for naming or switching Spaces
- Accessibility permission for workspace save/restore
- Automation permission only when saving or restoring Chrome/Safari tab URLs

SpaceNamer uses unsupported private macOS APIs. Apple can change those APIs in a
future macOS release; see the platform limitations below.

## Build and run

```bash
./build.sh
open build/SpaceNamer.app
```

Development builds are ad-hoc signed and written only to ignored `build/`.
There is no Xcode project: `build.sh` invokes `swiftc` and embeds the vendored
Sparkle 2.9.4 framework.

## Releases and updates

The canonical repository, release assets, and Sparkle feed are all at
<https://github.com/ZipLyne-Agency/SpaceNamer>. Releases are deliberately gated:
maintainers manually dispatch `.github/workflows/release.yml` with a numeric
version. Bundle builds are derived deterministically from that version. The
workflow uses the same repository's `github.token`; it does not
need a cross-repository personal access token.

The workflow builds and Developer-ID signs the app, notarizes and staples it,
Developer-ID signs the DMG container, notarizes and staples the DMG, verifies
Gatekeeper, signs the final DMG with Sparkle EdDSA, independently verifies that
signature, publishes the release, and updates `appcast.xml` idempotently. See
[`docs/RELEASING.md`](docs/RELEASING.md).

Versions through 3.1.18 were published from the historical
`spacenamer-releases` repository. Their URLs remain in the canonical appcast so
existing release history stays valid. Version 3.1.19 is the one-time bridge that
moves installed copies to this repository's feed.

## How it works

- Reads spaces via private `SkyLight.framework` (`CGSCopyManagedDisplaySpaces`).
- Switching uses `CGSManagedDisplaySetCurrentSpace` — direct, instant, no Mission Control
  round-trip and no Accessibility permission (the old AX-press approach is dead on macOS 26,
  see below).
- Custom names live in `UserDefaults` under `SpaceNames_v3`, keyed by space UUID.
  The UUID is persisted by WindowServer in `com.apple.spaces.plist`, so it survives reboots;
  reordering spaces in Mission Control does not change a space's UUID, so names travel with
  their desktop.
- "Launch at Login" installs a LaunchAgent (`~/Library/LaunchAgents/com.isaac.spacenamer.plist`);
  SMAppService silently fails for ad-hoc signed apps, so a LaunchAgent is the reliable path.

`com.isaac.spacenamer` is intentionally retained as the bundle identifier and
LaunchAgent label. It is now a compatibility identifier: changing it would
silently strand existing names, preferences, permissions, and login settings.

## Workspaces (save & restore window layouts)

Menu → **Save Layout as Workspace** (or ⌃⌥⌘S) captures every open window of every
app across all your desktops: app, title, frame, and which named desktop it lives on
(keyed by space UUID, so layouts survive desktop reordering). Menu → **Restore
Workspace** (or ⌃⌥⌘R) puts it all back:

- Windows already on their correct desktop are repositioned/resized to the saved frame.
- Apps that aren't running are launched **onto their saved desktop** (SpaceNamer tours
  the desktops in order via `CGSManagedDisplaySetCurrentSpace`, launching each app on
  its own desktop, then returns you to the desktop you started from).
- Chrome/Safari windows are recreated with their saved tab URLs when possible
  (requires approving SpaceNamer in System Settings → Privacy & Security → Automation
  the first time).
- "Restore Workspace at Login" runs the restore automatically after a reboot —
  the "click once and my whole setup comes back" flow.

Saved state: `~/Library/Application Support/SpaceNamer/workspace.json`.
Requires Accessibility permission (moving/resizing other apps' windows) — the app
asks once.

### macOS 26 hard limitation: windows can't be moved between desktops

Every known API for moving an existing window to another Space is dead on macOS 26.5.2
(verified on this machine with a clean test window):
`SLSMoveWindowsToManagedSpace`, the `SLSSpaceSetCompatID`+`SLSSetWindowListWorkspace`
compat dance (the yabai/Hammerspoon 14.5+ workaround), `SLSAdd/RemoveWindowsTo/FromSpaces`,
and `SLSBridgedMoveWindowsToManagedSpaceOperation` + `invokeFallback` — all silently
no-op. Driving Mission Control with synthetic drags is the only remaining route and
is too fragile to ship.

So restore works like this: windows on the right desktop get their saved frames; apps
that aren't running get launched onto the right desktop; windows sitting on the
**wrong** desktop are reported as left-behind (the restore summary tells you — drag
them once in Mission Control and they'll be captured correctly on the next save).
After a reboot nothing is running, so this limitation doesn't apply — the main
restore scenario is fully covered.

## Mission Control overlay

SpaceNamer can draw your custom names directly onto Mission Control's desktop
strip (toggle: menu → "Names in Mission Control", on by default). While Mission
Control is open and its spaces bar is expanded to thumbnails, a click-through,
non-activating window at `.screenSaver` level renders a pill with each named
space's custom name exactly over the native label.

- MC open/close is detected via `CGWindowList` (Dock's fullscreen window) — no
  permissions needed.
- Bar expansion is latched from the pointer entering the compact strip
  (`NSEvent.mouseLocation`) so pills only appear while the bar is expanded.
- Label geometry was measured empirically on macOS 26 (see comments in
  `main.swift`): the expanded row is centered as a group with per-item spacing
  that depends on the space count.
- Names are keyed by space UUID, so pills follow their desktop when you reorder
  spaces in Mission Control (verified live).

Known limitations: pills are positioned from measured geometry, not from Dock's
internals — if you horizontally scroll an overflowing spaces bar, pills stay at
the default scroll position (the common case — open MC, look, click — is exact).
The collapsed (compact) strip shows native labels; hover expands it and the
pills appear.

## Why the pills instead of renaming the real labels

Verified on macOS 26.5.2 (Apple Silicon), this machine, 2026-07-18:

- **`SLSSpaceSetName` / `CGSSpaceSetName` exist and work** — the name is stored server-side
  and persisted to `com.apple.spaces.plist`. **Dock ignores it for user desktops.** Mission
  Control keeps rendering `Desktop N` (generated from a localized `Desktop %@` format string
  by thumbnail position). Side effect: the call rewrites the space's UUID to the name, so it's
  not used here.
- **Mission Control's UI is completely invisible to the Accessibility API on macOS 26**: the
  Dock exposes no `mc` group, no `AXWindows`, and hit-testing the spaces bar returns no
  Dock-owned elements. So AX-writing the real label text is impossible, and the old
  AX-press-to-switch code in v2 could never have worked on this OS.
- The only ways names *inside* Mission Control have ever been done:
  1. **Code injection into Dock** (spaces-renamer / MacForge) — needs SIP disabled, and is
     broken on Apple Silicon since macOS 14.4. Not viable on this machine.
  2. **An overlay window** drawn on top of Mission Control (SpaceJump, Nook, Rename Spaces) —
     the only technique that works with SIP on. This is what SpaceNamer does.

So: the real labels can't be renamed — that is a macOS platform limitation, not
a bug in this app — but the overlay puts your names in the same place.

## Verified system facts (macOS 26.5.2)

- `CGSManagedDisplaySetCurrentSpace(cid, displayID, spaceID)` switches spaces with no
  permissions — used for click-to-switch.
- Opening Mission Control programmatically: `openApplication` on
  `/System/Applications/Mission Control.app` works; `com.apple.expose.awake` distributed
  notification and CGEvent-posted Ctrl+Up are unreliable on macOS 26.
- Space UUIDs are stable across reorders and reboots; `ManagedSpaceID` is not (regenerates).
