import Cocoa
import Darwin
import LetsMove
import ShortcutRecorder
import AppCenterCrashes

class App: AppCenterApplication {
    /// periphery:ignore
    static let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
        reason: "Prevent App Nap to preserve responsiveness")
    static let bundleIdentifier = Bundle.main.bundleIdentifier!
    static let bundleURL = Bundle.main.bundleURL
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as! String
    /// Custom-build version string shown in the About panel. Reads the
    /// bundle-plist value (normally `#VERSION#` placeholder from a local
    /// build) and prepends a clear "CUSTOM BUILD" marker so it's obvious
    /// the user is running our patched version rather than the official
    /// release. The timestamp is baked at compile time via the BUILD_DATE
    /// preprocessor-ish approach — we use a static string updated by the
    /// local build wrapper script.
    static let version: String = {
        let bundleVersion = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "unknown"
        let buildDate = "BUILD_DATE_PLACEHOLDER" // updated by build script
        return "CUSTOM BUILD (\(buildDate)) — base:\(bundleVersion)"
    }()
    static let licence = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as! String
    static let repository = "https://github.com/lwouis/alt-tab-macos"
    static let website = "https://alt-tab.app"
    static let appIcon = CGImage.named("app.icns")
    override class var shared: App { super.shared as! App }
    static var supportProjectAction: Selector { #selector(App.supportProject) }
    static var isTerminating = false
    static var appIsBeingUsed = false
    static var shortcutIndex = 0
    static var forceDoNothingOnRelease = false
    /// Captured at the start of each AltTab session so that focus() can tell
    /// which window was REALLY in the foreground when the user hit Alt-Tab.
    /// Tracked by CGWindowID (not pid) so that switching between two
    /// windows of the same app (e.g. two OneNote windows both under a
    /// single Parallels winapp process) properly rotates between them.
    static var sessionSourceWid: CGWindowID?
    /// The `sessionSourceWid` from the PREVIOUS AltTab session — the
    /// window the user was on before they alt-tabbed to the current
    /// foreground. Used to set position 1 in the switcher list.
    static var previousSessionSourceWid: CGWindowID?
    /// The last target wid we focused via our own AltTab transition.
    /// This is the ground truth for "which window is currently
    /// foreground" — more reliable than `Applications.frontmostPid`
    /// (which can be flipped by delayed Parallels AX events after our
    /// guard expires) or NSWorkspace (which lags). Used at session
    /// start to decide the current frontmost window when other signals
    /// disagree.
    static var lastFocusedTargetWid: CGWindowID?
    /// pid of the same target. Used by CLICKMISROUTE to distinguish
    /// "wrong app" (cross-pid) from "different window of same app"
    /// (cross-wid, same-pid) — the latter is usually just user
    /// clicking outside a small alt-tab target's bounds, not a bug.
    static var lastFocusedTargetPid: pid_t?
    /// When `lastFocusedTargetWid` was last set. Used by the
    /// CLICKMISROUTE diagnostic to age-out the "expected target" so a
    /// user clicking around 30 seconds after a switch isn't flagged as
    /// a misroute.
    static var lastFocusedTargetTime: CFAbsoluteTime?
    /// Register-once guard for the global mouse-click NSEvent monitor.
    /// Without this, duplicate `[DIAG MOUSE]` lines appeared per click.
    static var globalClickMonitorRegistered = false
    /// Mirror of `sessionSourceWid` as a pid, exposed as before for the
    /// existing Parallels-outbound detection which only needs to know
    /// the source app. Kept in sync via rotation.
    static var sessionSourcePid: pid_t? {
        guard let wid = sessionSourceWid,
              let w = (Windows.list.first { $0.cgWindowId == wid }) else { return nil }
        return w.application.pid
    }
    private static var isFirstSummon = true
    private static var isVeryFirstSummon = true
    private static var pendingShowSettingsWindow = false
    // periphery:ignore
    private static var appCenterDelegate: AppCenterCrash?
    // don't queue multiple delayed rebuildUi() calls
    private static var delayedDisplayScheduled = 0
    private static let refreshOpenUiThrottler = Throttler(delayInMs: 200)

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    /// we put application code here which should be executed on init() and Preferences change
    static func resetPreferencesDependentComponents() {
        TilesView.reset()
    }

    private static var didCallRestart = false
    private static let restartLockPath = "/tmp/alttab-restart.lock"
    private static let restartLockWindowMs: Double = 5000

    static func restart() {
        // Why this is a fork-bomb without a guard: there are ~9 callers of
        // restart() — almost all "if my event tap couldn't be created,
        // bounce the process". When TCC for Input Monitoring is in a
        // flaky state (e.g., multiple registered code-signatures, fresh
        // rebuild not yet authorized), every spawned process fails the
        // same way, calls restart(), spawns ANOTHER one with `open -n`
        // (which bypasses the running-instance check), and dies. The
        // children survive their parent. Within seconds the screen is
        // littered with PermissionsWindow popups from many parallel
        // instances.
        //
        // Two-tier guard:
        //  1. Process-local: each instance restarts at most once.
        //  2. Filesystem mtime: if ANY instance restarted within the
        //     last 5s, suppress this one — just terminate without
        //     spawning a successor. The first restarter wins.
        if didCallRestart {
            Logger.error { "restart() called twice in same process — ignoring" }
            return
        }
        didCallRestart = true
        let now = Date().timeIntervalSince1970
        if let attrs = try? FileManager.default.attributesOfItem(atPath: restartLockPath),
           let mtime = attrs[.modificationDate] as? Date {
            let ageMs = (now - mtime.timeIntervalSince1970) * 1000
            if ageMs < restartLockWindowMs {
                Logger.error { "restart() suppressed: another instance restarted \(Int(ageMs))ms ago — terminating only" }
                App.shared.terminate(nil)
                return
            }
        }
        try? "\(now)".write(toFile: restartLockPath, atomically: true, encoding: .utf8)
        // we use -n to open a new instance, to avoid calling applicationShouldHandleReopen
        // we use Bundle.main.bundlePath in case of multiple AltTab versions on the machine
        printStackTrace()
        Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-n", Bundle.main.bundlePath])
        App.shared.terminate(nil)
    }

    static func hideUi(_ keepPreview: Bool = false) {
        Logger.info { "appIsBeingUsed:\(appIsBeingUsed)" }
        guard appIsBeingUsed else { return } // already hidden
        Diagnostics.log("PANEL", "hideUi keepPreview=\(keepPreview)")
        // Phase 1 — sync state flip + the visible step. `appIsBeingUsed=false`
        // first so the deferred-cleanup re-entry guard is correct; tile-panel
        // orderOut second so the user-perceived latency for Mac→Mac ends here
        // (target window has already been raised by `window.focus()` upstream
        // under H1 ordering, so the orderOut reveals it instantly).
        // `sessionSourcePid` intentionally NOT cleared — overwritten in
        // `showUiOrCycleSelection` on the next session.
        appIsBeingUsed = false
        isFirstSummon = true
        forceDoNothingOnRelease = false
        hideTilesPanelWithoutChangingKeyWindow()
        // Phase 2 — defer the slow cleanup to the next runloop. Event-tap
        // teardown (CursorEvents/ContextMenuEvents), tooltip private-API
        // call, and MainMenu rebuild together cost 10–50 ms on the main
        // thread; running them inline pushed the perceived end-of-switch
        // out by that amount. The deferred handlers all guard on
        // `appIsBeingUsed`, so a re-entrant Cmd-Tab arriving in this
        // window finds the flag already false and behaves correctly.
        DispatchQueue.main.async {
            UsageStats.resetSession()
            TilesView.endSearchSession()
            ContextMenuEvents.toggle(false)
            CursorEvents.toggle(false)
            TrackpadEvents.reset()
            if !keepPreview {
                PreviewPanel.shared.orderOut(nil)
            }
            hideAllTooltips()
            MainMenu.toggle(true)
        }
    }

    /// some tooltips may not be hidden when the main window is hidden; we force it through a private API
    private static func hideAllTooltips() {
        let selector = NSSelectorFromString("abortAllToolTips")
        if NSApp.responds(to: selector) {
            NSApp.perform(selector)
        }
    }

    /// we don't want another window to become key when the TilesPanel is hidden
    static func hideTilesPanelWithoutChangingKeyWindow() {
        allSecondaryWindowsCanBecomeKey(false)
        TilesPanel.shared.orderOut(nil)
        allSecondaryWindowsCanBecomeKey(true)
    }

    private static func allSecondaryWindowsCanBecomeKey(_ canBecomeKey_: Bool) {
        SettingsWindow.canBecomeKey_ = canBecomeKey_
        AboutWindow.canBecomeKey_ = canBecomeKey_
        PermissionsWindow.canBecomeKey_ = canBecomeKey_
        FeedbackWindow.canBecomeKey_ = canBecomeKey_
        DebugWindow.canBecomeKey_ = canBecomeKey_
    }

    static func closeSelectedWindow() {
        Windows.selectedWindow()?.close()
    }

    static func minDeminSelectedWindow() {
        Windows.selectedWindow()?.minDemin()
    }

    static func toggleFullscreenSelectedWindow() {
        Windows.selectedWindow()?.toggleFullscreen()
    }

    static func quitSelectedApp() {
        Windows.selectedWindow()?.application.quit()
    }

    static func hideShowSelectedApp() {
        Windows.selectedWindow()?.application.hideOrShow()
    }

    static func toggleSearchMode() {
        guard appIsBeingUsed else { return }
        TilesView.toggleSearchModeFromShortcut()
    }

    static func lockSearchMode() {
        guard appIsBeingUsed, TilesView.isSearchModeOn else { return }
        TilesView.lockSearchMode()
    }

    static func cancelSearchModeOrHideUi() {
        guard appIsBeingUsed else { return }
        if TilesView.isSearchModeOn {
            TilesView.disableSearchMode()
        } else {
            hideUi()
        }
    }

    static func focusTarget() {
        guard appIsBeingUsed else { return } // already hidden
        Diagnostics.markSwitchPhase("focusTarget")
        let selectedWindow = Windows.selectedWindow()
        Logger.info { selectedWindow?.debugId }
        focusSelectedWindow(selectedWindow)
    }

    @objc static func checkForUpdatesNow(_ sender: NSMenuItem) {
        GeneralTab.checkForUpdatesNow(sender)
    }

    @objc static func checkPermissions(_ sender: NSMenuItem) {
        showPermissionsWindow()
    }

    @objc static func supportProject() {
        NSWorkspace.shared.open(URL(string: App.website + "/support")!)
    }

    @objc static func showFeedbackPanel() {
        initializeFeedbackWindowIfNeeded()
        showSecondaryWindow(FeedbackWindow.shared!)
    }

    @objc static func showDebugWindow() {
        initializeDebugWindowIfNeeded()
        showSecondaryWindow(DebugWindow.shared!)
    }

    @objc static func showSettingsWindow() {
        guard Menubar.statusItem != nil else {
            pendingShowSettingsWindow = true
            return
        }
        initializeSettingsWindowIfNeeded()
        showSecondaryWindow(SettingsWindow.shared!)
        if SettingsWindow.shared!.isVisible != true {
            let window = SettingsWindow()
            showSecondaryWindow(window)
            window.orderFrontRegardless()
        }
    }

    @objc static func toggleOverlayMode() {
        let newValue = !FocusOverlay.overlayModeEnabled
        UserDefaults.standard.set(newValue, forKey: "overlayMode")
        updateParallelsMenuStates()
        if newValue {
            if #available(macOS 14.0, *) {
                FocusOverlay.createPersistentOverlay()
                FocusOverlay.startBackgroundRefresh()
            }
        } else {
            FocusOverlay.dismiss()
            FocusOverlay.clearPreCaptureCache()
            FocusOverlay.stopBackgroundRefresh()
        }
        Diagnostics.log("OVERLAY", "overlay mode \(newValue ? "ON" : "OFF")")
    }

    @objc static func toggleHideSource() {
        let key = "hideSourceWindow"
        let newValue = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(newValue, forKey: key)
        updateParallelsMenuStates()
        Diagnostics.log("HIDE", "hide source window \(newValue ? "ON" : "OFF")")
    }

    @objc static func toggleCoherencePreviews() {
        let key = "disableCoherencePreviews"
        let newDisabled = !UserDefaults.standard.bool(forKey: key)
        UserDefaults.standard.set(newDisabled, forKey: key)
        updateParallelsMenuStates()
    }

    @objc static func toggleDiagnostics() {
        let key = "diagnosticsEnabled"
        let newValue = !Diagnostics.enabled
        UserDefaults.standard.set(newValue, forKey: key)
        updateParallelsMenuStates()
    }

    @objc static func toggleWinsideHelper() {
        let newValue = !Winside.isEnabled
        Winside.setEnabled(newValue)
        updateParallelsMenuStates()
    }

    private static func updateParallelsMenuStates() {
        guard let parallelsItem = Menubar.menu.items.first(where: { $0.title == "Parallels Mode" }),
              let sub = parallelsItem.submenu else { return }
        for item in sub.items {
            switch item.title {
            case "Enable Overlay Mode": item.state = FocusOverlay.overlayModeEnabled ? .on : .off
            case "Hide Source Window": item.state = UserDefaults.standard.bool(forKey: "hideSourceWindow") ? .on : .off
            case "Coherence Thumbnails": item.state = !UserDefaults.standard.bool(forKey: "disableCoherencePreviews") ? .on : .off
            case "Diagnostics Logging": item.state = Diagnostics.enabled ? .on : .off
            case "Windows Helper (Phase 3 IPC)": item.state = Winside.isEnabled ? .on : .off
            default: break
            }
        }
    }

    @objc static func showAboutWindow() {
        initializeAboutWindowIfNeeded()
        showSecondaryWindow(AboutWindow.shared!)
    }

    static func showSecondaryWindow(_ window: NSWindow) {
        NSScreen.updatePreferred()
        App.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // if the window was resized/repositioned by the user, restore the window the way it was
        let restored = window.setFrameUsingName(window.frameAutosaveName)
        if !restored {
            NSScreen.preferred.repositionPanel(window)
            // Use the center function to continue to center, the `repositionPanel` function cannot center, it may be a system bug
            window.center()
        }
    }

    private static func initializeSettingsWindowIfNeeded() {
        if SettingsWindow.shared == nil { _ = SettingsWindow() }
    }

    private static func initializeAboutWindowIfNeeded() {
        if AboutWindow.shared == nil { _ = AboutWindow() }
    }

    private static func initializeFeedbackWindowIfNeeded() {
        if FeedbackWindow.shared == nil { _ = FeedbackWindow() }
    }

    private static func initializeDebugWindowIfNeeded() {
        if DebugWindow.shared == nil { _ = DebugWindow() }
    }

    private static func initializePermissionsWindowIfNeeded() {
        if PermissionsWindow.shared == nil { _ = PermissionsWindow() }
    }

    @discardableResult
    private static func showSettingsWindowOnFirstLaunchIfNeeded() -> Bool {
        guard !Preferences.settingsWindowShownOnFirstLaunch else { return false }
        showSettingsWindow()
        Preferences.markSettingsWindowShownOnFirstLaunch()
        return true
    }

    static func showPermissionsWindow() {
        initializePermissionsWindowIfNeeded()
        PermissionsWindow.show()
    }

    static func showUi(_ shortcutIndex: Int) {
        showUiOrCycleSelection(shortcutIndex, true)
    }

    @objc static func showUiFromShortcut0() {
        showUi(0)
    }

    static func cycleSelection(_ direction: Direction, allowWrap: Bool = true) {
        (TilesView.scrollView?.documentView as? TilesDocumentView)?.cancelDraggingTimer()
        CursorEvents.resetDeadzone()
        if direction == .up || direction == .down {
            TilesView.navigateUpOrDown(direction, allowWrap: allowWrap)
        } else {
            Windows.cycleSelectedWindowIndex(direction.step(), allowWrap: allowWrap)
        }
    }

    static func previousWindowShortcutWithRepeatingKey() {
        cycleSelection(.trailing)
        KeyRepeatTimer.startRepeatingKeyPreviousWindow()
    }

    private static var lastFocusTime: CFAbsoluteTime = 0
    private static var lastFocusWid: CGWindowID?

    static func focusSelectedWindow(_ selectedWindow: Window?) {
        guard appIsBeingUsed else { return } // already hidden
        // Debounce: ignore duplicate fires for the SAME target within 200ms.
        // Ghost fires happen from redundant holdShortcut/flagsChanged handlers.
        // Different targets always pass (legitimate fast switch).
        let now = CFAbsoluteTimeGetCurrent()
        let targetWid = selectedWindow?.cgWindowId
        if now - lastFocusTime < 0.2 && targetWid == lastFocusWid {
            Diagnostics.log("KEY", "DEBOUNCED duplicate focusSelectedWindow (gap=\(Int((now - lastFocusTime) * 1000))ms)")
            return
        }
        lastFocusTime = now
        lastFocusWid = targetWid
        // Click-time live-title check for Parallels Coherence windows.
        // If the panel-build refresh missed an update (or the user
        // navigated OneNote between panel-show and click), this catches
        // the divergence and refreshes before logging the KEY line.
        // Surfaces the "tile said X but live says Y" failure mode.
        if let w = selectedWindow, w.isParallelsCoherenceWindow,
           let axElement = w.axUiElement, let wid = w.cgWindowId {
            var titleValue: AnyObject?
            if AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleValue) == .success,
               let liveTitle = titleValue as? String, !liveTitle.isEmpty,
               liveTitle != w.title {
                Diagnostics.log("TITLEMISS", "wid=\(wid) tile-said='\(w.title ?? "")' live-at-click='\(liveTitle)'")
                w.refreshTitleIfChanged(liveTitle)
            }
        }
        Diagnostics.markSwitchPhase("focusSelectedWindow", extra: "wid=\(targetWid?.description ?? "nil")")
        Diagnostics.log("KEY", "release → focusSelectedWindow target=\(selectedWindow?.debugId ?? "nil")")
        Diagnostics.logFrontmostQuick("pre-focus")
        // Light z-order sampling: 5 samples over 1s (not 25 over 5s).
        // Enough to diagnose z-order issues without GPU/CPU churn.
        Diagnostics.sampleZOrderOverTime(label: "focus-\(selectedWindow?.cgWindowId ?? 0)", durationMs: 1000, intervalMs: 200)
        // Show the TARGET window's cached content on an overlay at max
        // level. Terminal stays visible regardless of Parallels' re-raise.
        // IOSurface→CGImage conversion via CIContext (GPU, fast).
        // Overlay mode: toggle via defaults write com.lwouis.alt-tab-macos overlayMode -bool true/false
        if FocusOverlay.overlayModeEnabled {
            if let window = selectedWindow {
                let targetIsPar = window.isParallelsCoherenceWindow
                let sourceIsPar = App.sessionSourcePid.flatMap { pid in
                    Applications.list.first { $0.pid == pid }?.isParallelsCoherence
                } ?? false
                if targetIsPar || sourceIsPar {
                    FocusOverlay.showTarget(window, duration: 1.5)
                } else {
                    FocusOverlay.dismiss()
                }
            }
        }
        // For Parallels-involved transitions: raise the target FIRST
        // while the switcher panel (L101) acts as a "curtain" covering
        // everything. The target renders underneath. Then dismiss the
        // panel after a short delay — target is already in place.
        let isParInvolved: Bool = {
            guard let w = selectedWindow else { return false }
            if w.isParallelsCoherenceWindow { return true }
            return App.sessionSourcePid.flatMap { pid in
                Applications.list.first { $0.pid == pid }?.isParallelsCoherence
            } ?? false
        }()
        if isParInvolved {
            if let window = selectedWindow, MissionControl.state() == .inactive || MissionControl.state() == .showDesktop {
                Diagnostics.markSwitchPhase("preFocus", extra: "par=true")
                window.focus()
                if Preferences.cursorFollowFocus == .always || (
                    Preferences.cursorFollowFocus == .differentScreen && (Spaces.screenSpacesMap.first { $0.value.contains { space in window.spaceIds.contains(space) } })?.key != NSScreen.active()?.cachedUuid()) {
                    moveCursorToSelectedWindow(window)
                }
            } else {
                PreviewPanel.shared.orderOut(nil)
            }
            // Delay panel dismiss — target is now raising under the curtain.
            // Original: 200 ms; user reported Par→Par "noticeably slow" — that
            // 1/5-second wait was the dominant felt latency. With the
            // tightened ZENFORCE early-phase ticks (5/12/25 ms) actively
            // re-raising the target if Parallels' coherence sync momentarily
            // bumps it, a much shorter curtain is sufficient. Default 30 ms
            // ≈ 2 display frames at 60 Hz; user can dial via
            // `defaults write com.lwouis.alt-tab-macos parHideUiDelayMs -int N`
            // if a specific Parallels workload needs more (or less).
            let parHideUiDelayMs = UserDefaults.standard.object(forKey: "parHideUiDelayMs") as? Int ?? 30
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(parHideUiDelayMs)) {
                hideUi(true)
            }
        } else {
            // Non-Parallels: focus FIRST, then dismiss the panel. Prior
            // order called hideUi(true) synchronously (~25-75ms on the
            // event-tap teardown path), so SLPS didn't fire until after
            // the panel had already disappeared and the previous frontmost
            // briefly re-rendered. Reordering pushes SLPS to t=0, hides
            // the panel afterward — the popUpMenu-level TilesPanel keeps
            // the visual curtain up while the target raises beneath it.
            // Same logic the Parallels branch above already relies on.
            if let window = selectedWindow, MissionControl.state() == .inactive || MissionControl.state() == .showDesktop {
                Diagnostics.markSwitchPhase("preFocus", extra: "par=false")
                window.focus()
                if Preferences.cursorFollowFocus == .always || (
                    Preferences.cursorFollowFocus == .differentScreen && (Spaces.screenSpacesMap.first { $0.value.contains { space in window.spaceIds.contains(space) } })?.key != NSScreen.active()?.cachedUuid()) {
                    moveCursorToSelectedWindow(window)
                }
            } else {
                PreviewPanel.shared.orderOut(nil)
            }
            Diagnostics.markSwitchPhase("preHideUi")
            hideUi(true)
        }
    }

    static func moveCursorToSelectedWindow(_ window: Window) {
        let referenceWindow = window.referenceWindowForTabbedWindow()
        guard let position = referenceWindow?.position, let size = referenceWindow?.size else { return }
        let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        CGWarpMouseCursorPosition(point)
    }

    static func refreshOpenUiAfterExternalEvent(_ windowsToScreenshot: [Window], windowRemoved: Bool = false) {
        Windows.refreshThumbnailsAsync(windowsToScreenshot, .refreshUiAfterExternalEvent, windowRemoved: windowRemoved)
        refreshOpenUiThrottler.throttleOrProceed {
            guard appIsBeingUsed else { return }
            if !Windows.updatesBeforeShowing() { hideUi(); return }
            refreshUi(true)
        }
    }

    static func refreshUi(_ preserveScrollPosition: Bool = false) {
        guard appIsBeingUsed else { return }
        let preservedScrollOrigin = preserveScrollPosition ? TilesView.currentScrollOrigin() : nil
        Windows.updateSelectedWindow()
        guard appIsBeingUsed else { return }
        TilesPanel.shared.updateContents(preservedScrollOrigin)
        guard appIsBeingUsed else { return }
        Windows.voiceOverWindow() // at this point TileViews are assigned to the window, and ready
        guard appIsBeingUsed else { return }
        Windows.previewSelectedWindowIfNeeded()
        guard appIsBeingUsed else { return }
        Applications.refreshBadgesAsync()
    }

    static func showUiOrCycleSelection(_ shortcutIndex: Int, _ forceDoNothingOnRelease_: Bool) {
        forceDoNothingOnRelease = forceDoNothingOnRelease_
        Logger.debug { "isFirstSummon:\(isFirstSummon) shortcutIndex:\(shortcutIndex)" }
        // Capture the REAL source app before the TilesPanel shows and possibly
        // steals key-window status. Needed for the Parallels Coherence outbound
        // fix — otherwise `Applications.frontmostPid` reads as AltTab's own pid
        // by the time `Window.focus()` runs.
        if !appIsBeingUsed {
            // Overlay stays at L50 (below switcher's L101) — no need to
            // dismiss. Switcher draws above, overlay covers Parallels below.
            Diagnostics.log("SESSION", "new session shortcutIndex=\(shortcutIndex)")
            Diagnostics.logFrontmostSignals("session-start pre")
            Diagnostics.logTrackedRecency("session-start pre")
            // Prefer the LIVE AX-based source of truth: current frontmost
            // app + its focused window. This is kept current by
            // AccessibilityEvents for mac→mac transitions AND by our
            // manualUpdate for Parallels transitions. Fall back to
            // lastFocusedTargetWid only if the live path returns nil.
            //
            // Bug that motivated this order: lastFocusedTargetWid is
            // only set by our Parallels-involved paths. After a pure
            // mac→mac AltTab, the Par-era wid lingered; using it as
            // "current source" at next session start caused normalize
            // to promote the wrong window to position 0.
            let newSourceWid: CGWindowID? = {
                if let pid = Applications.frontmostPid,
                   let app = (Applications.list.first { $0.pid == pid }),
                   let focused = app.focusedWindow {
                    return focused.cgWindowId
                }
                if let wid = lastFocusedTargetWid,
                   Windows.list.contains(where: { $0.cgWindowId == wid }) {
                    return wid
                }
                return nil
            }()
            if newSourceWid != sessionSourceWid {
                previousSessionSourceWid = sessionSourceWid
                sessionSourceWid = newSourceWid
                // Only normalize when the LAST ALT-TAB TARGET was a
                // Parallels window (meaning AX recency may be unreliable
                // for that transition). Don't normalize based on session
                // source — a link click in Outlook opening Safari changes
                // the source but AX recency is already correct.
                let lastTargetIsPar = lastFocusedTargetWid.flatMap { wid in
                    Windows.list.first { $0.cgWindowId == wid }?.application.isParallelsCoherence
                } ?? false
                if lastTargetIsPar {
                    Windows.normalizeFocusOrderAtSessionStart(
                        currentWid: sessionSourceWid,
                        previousWid: previousSessionSourceWid)
                }
            }
            Diagnostics.logFrontmostSignals("session-start post")
            Diagnostics.logTrackedRecency("session-start post")
        }
        appIsBeingUsed = true
        UsageStats.recordTrigger(shortcutIndex)
        if isFirstSummon || shortcutIndex != App.shortcutIndex {
            NSScreen.updatePreferred()
            if isVeryFirstSummon {
                Windows.sortByLevel()
                isVeryFirstSummon = false
            }
            isFirstSummon = false
            App.shortcutIndex = shortcutIndex
            let shouldStartInSearchMode = Preferences.shortcutStyle == .searchOnRelease
            TilesView.startSearchSession(shouldStartInSearchMode)
            if shouldStartInSearchMode {
                forceDoNothingOnRelease = true
            }
            if !Windows.updatesBeforeShowing() { hideUi(); return }
            Windows.setInitialSelectedAndHoveredWindowIndex()
            // Pre-capture ONLY the selected window at retina. Multiple
            // parallel CGWindowListCreateImage calls serialize on the
            // window server lock — 4 parallel = 28s total. One = 1-2s.
            if let selected = Windows.selectedWindow(),
               let wid = selected.cgWindowId,
               let pos = selected.position, let sz = selected.size {
                if #available(macOS 14.0, *) {
                    FocusOverlay.preCapture(wid: wid, position: pos, size: sz)
                }
            }
            // Use longer delay when source is a Parallels Coherence window
            // to allow fast-switch without showing the panel (reduces flicker).
            // defaults write com.lwouis.alt-tab-macos coherenceDisplayDelay -int 500
            // Use coherence delay when EITHER source or any top-2 target
            // is a Parallels window. Parallels transitions are visually
            // noisy, so suppress the panel for fast switches in both
            // directions (Par→mac AND mac→Par).
            let isCoherenceSource = App.sessionSourcePid.flatMap { pid in
                Applications.list.first { $0.pid == pid }?.isParallelsCoherence
            } ?? false
            // Check only the fast-switch target (position 1 = what a quick
            // alt-tab selects). Don't check top 3 — that triggers coherence
            // delay for ALL sessions when any Parallels window is recent.
            let fastSwitchTarget = Windows.list
                .sorted { $0.lastFocusOrder < $1.lastFocusOrder }
                .dropFirst() // skip position 0 (current)
                .first
            let isCoherenceTarget = fastSwitchTarget?.application.isParallelsCoherence ?? false
            let isCoherenceInvolved = isCoherenceSource || isCoherenceTarget
            let coherenceMs = UserDefaults.standard.integer(forKey: "coherenceDisplayDelay")
            let delay: DispatchTimeInterval = isCoherenceInvolved
                ? .milliseconds(coherenceMs)
                : Preferences.windowDisplayDelay
            Diagnostics.log("PANEL", "display delay: \(isCoherenceInvolved ? "\(coherenceMs)ms (coherence src=\(isCoherenceSource) tgt=\(isCoherenceTarget))" : "\(Preferences.windowDisplayDelay) (normal)")")
            if delay == .milliseconds(0) {
                buildUiAndShowPanel()
            } else {
                delayedDisplayScheduled += 1
                DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + delay) { () -> () in
                    if delayedDisplayScheduled == 1 {
                        buildUiAndShowPanel()
                    }
                    delayedDisplayScheduled -= 1
                }
            }
        } else {
            cycleSelection(.leading)
            KeyRepeatTimer.startRepeatingKeyNextWindow()
        }
    }

    static func buildUiAndShowPanel() {
        guard appIsBeingUsed else { return }
        Appearance.update()
        guard appIsBeingUsed else { return }
        refreshUi()
        guard appIsBeingUsed else { return }
        Diagnostics.log("PANEL", "showPanel (window count=\(Windows.list.count))")
        TilesPanel.shared.show()
        Windows.previewSelectedWindowIfNeeded()
        if TilesView.isSearchEditing {
            TilesView.enableSearchEditing()
        }
        KeyRepeatTimer.startRepeatingKeyNextWindow()
        Windows.refreshThumbnailsAsync(Windows.list, .refreshOnlyThumbnailsAfterShowUi)
    }

    static func checkIfShortcutsShouldBeDisabled(_ activeWindow: Window?, _ activeApp: Application?) {
        let app = activeWindow?.application ?? activeApp!
        let shortcutsShouldBeDisabled = Preferences.exceptions.contains { exception in
            if let id = app.bundleIdentifier {
                return id.hasPrefix(exception.bundleIdentifier) &&
                    (exception.ignore == .always || (exception.ignore == .whenFullscreen && (activeWindow?.isFullscreen ?? false)))
            }
            return false
        }
        KeyboardEvents.toggleGlobalShortcuts(shortcutsShouldBeDisabled)
        if shortcutsShouldBeDisabled && appIsBeingUsed {
            hideUi()
        }
    }

    static func continueAppLaunchAfterPermissionsAreGranted() {
        Logger.info { "System permissions are granted; continuing launch" }
        BackgroundWork.start()
        NSScreen.updatePreferred()
        Appearance.update()
        TilesPanel.updateMaxPossibleThumbnailSize()
        TilesPanel.updateMaxPossibleAppIconSize()
        Menubar.initialize()
        MainMenu.create()
        _ = TilesPanel()
        _ = PreviewPanel()
        Spaces.refresh()
        Screens.refresh()
        SpacesEvents.observe()
        ScreensEvents.observe()
        SystemAppearanceEvents.observe()
        SystemScrollerStyleEvents.observe()
        InputSourceEvents.observe()
        Applications.initialDiscovery()
        KeyboardEvents.addEventHandlers()
        CursorEvents.observe()
        TrackpadEvents.observe()
        CliEvents.observe()
        PreferencesEvents.initialize()
        BenchmarkRunner.startIfNeeded()
        showSettingsWindowOnFirstLaunchIfNeeded()
        if pendingShowSettingsWindow {
            pendingShowSettingsWindow = false
            showSettingsWindow()
        }
        #if DEBUG
//            App.showSettingsWindow()
        #endif
        UsageStats.prune()
        Logger.info { "Finished launching AltTab" }
    }
}

extension App: NSApplicationDelegate {
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Ignore SIGPIPE process-wide. Without this, any write to a
        // half-closed socket (e.g. the Winside TCP socket when the
        // guest helper has hung) raises SIGPIPE → silent process
        // death with NO crash report. We observed exactly this:
        // AltTab vanished mid-alt-tab leaving the user without a
        // window switcher and no diagnostic. Per-socket SO_NOSIGPIPE
        // is also set defensively, but this catches any other
        // unprotected write (NSPipe drains, prlctl IO, etc).
        signal(SIGPIPE, SIG_IGN)
        App.appCenterDelegate = AppCenterCrash()
        App.shared.disableRelaunchOnLogin()
        Logger.initialize()
        Logger.info { "Launching AltTab \(App.version)" }
        Diagnostics.log("INIT", "AltTab \(App.version) launched (custom build with diagnostics)")
        Diagnostics.startContinuousMonitoring()
        // Auto-run profiler if `runProfilerAtLaunch` is set in defaults.
        // Clears the flag immediately so a crash mid-run doesn't loop.
        // 8s settle delay ensures Windows.list has been populated by
        // the initial AX scan before we start picking targets.
        if UserDefaults.standard.bool(forKey: "runProfilerAtLaunch") {
            UserDefaults.standard.set(false, forKey: "runProfilerAtLaunch")
            // Optional override: `defaults write com.lwouis.alt-tab-macos
            // profilerDurationSeconds -int 180` for longer runs / better
            // statistical confidence. Default 60s gives ~21 attempts;
            // 180s gives ~60 attempts (~3% precision on bounce rate).
            let dur = UserDefaults.standard.object(forKey: "profilerDurationSeconds") as? Int ?? 60
            Diagnostics.log("PROFILER", "runProfilerAtLaunch=true; scheduling \(dur)s run in 8s")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
                Profiler.run(durationSeconds: TimeInterval(dur))
            }
        }
        // Phase 3 IPC: launch the Windows-side TCP helper (in the
        // Parallels guest) if the user has it enabled. Async — does
        // not block app launch. Default ON.
        Winside.startIfNeeded()
        if FocusOverlay.overlayModeEnabled {
            FocusOverlay.createPersistentOverlay()
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if #available(macOS 14.0, *) {
                    FocusOverlay.startBackgroundRefresh()
                }
            }
        }
        #if DEBUG
        UserDefaults.standard.set(true, forKey: "NSConstraintBasedLayoutVisualizeMutuallyExclusiveConstraints")
        #endif
        #if !DEBUG
        PFMoveToApplicationsFolderIfNecessary()
        #endif
        // Global mouse click monitor: tracks clicks to distinguish
        // user-initiated window activations from Parallels' automatic
        // re-activation during the focus guard period.
        // REGISTER-ONCE GUARD: empirically `[DIAG MOUSE]` was firing
        // twice per click — symptom of either an inadvertent double
        // call to applicationDidFinishLaunching or external HID
        // duplication. The guard ensures only the first registration
        // wins and logs the duplicate so it's diagnosable.
        if App.globalClickMonitorRegistered {
            Diagnostics.log("INIT", "duplicate addGlobalMonitorForEvents call suppressed")
        } else {
            App.globalClickMonitorRegistered = true
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp]) { event in
                let isDown = event.type == .leftMouseDown || event.type == .rightMouseDown
                let button = (event.type == .leftMouseDown || event.type == .leftMouseUp) ? "left" : "right"
                let action = isDown ? "down" : "up"
                if isDown {
                    Windows.lastMouseClickTime = CFAbsoluteTimeGetCurrent()
                }
                // Log click target: find topmost window at cursor position
                let pt = NSEvent.mouseLocation
                let screenHeight = NSScreen.main?.frame.height ?? 0
                let cgPoint = CGPoint(x: pt.x, y: screenHeight - pt.y)
                let skipOwners: Set<String> = [
                    "Window Server", "Control Center", "Dock", "AltTab",
                    "Notification Center", "SystemUIServer", "Spotlight",
                    "Menubar", "Wallpaper", "CursorUIViewService",
                    "LocalAuthenticationRemoteService",
                ]
                if isDown, let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                    for w in list {
                        let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
                        if skipOwners.contains(owner) { continue }
                        let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1.0
                        if alpha < 0.1 { continue }
                        guard let bounds = w[kCGWindowBounds as String] as? [String: Any],
                              let x = bounds["X"] as? Double, let y = bounds["Y"] as? Double,
                              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { continue }
                        let rect = CGRect(x: x, y: y, width: width, height: height)
                        if rect.contains(cgPoint) {
                            let name = (w[kCGWindowName as String] as? String) ?? ""
                            let wid = (w[kCGWindowNumber as String] as? Int) ?? 0
                            let ownerPid = (w[kCGWindowOwnerPID as String] as? Int32) ?? 0
                            let short = name.isEmpty ? owner : "\(owner):\(name.prefix(30))"
                            if isDown {
                                Windows.lastMouseClickWid = CGWindowID(wid)
                                Windows.lastMouseClickPid = ownerPid
                                Windows.lastMouseClickOwner = owner
                                // CRITICAL: when the user clicks a window
                                // belonging to a DIFFERENT app than the
                                // current AltTab focus target, release
                                // the guard. Without this,
                                // diagnoseFrontmostMismatch sees "target
                                // at z0 but frontmost-app is different"
                                // and fires SLPS to restore the old
                                // target — fighting the user's click and
                                // making it impossible to switch apps
                                // by clicking. The guard's purpose is
                                // to defend against silent self-
                                // activation; an explicit user click is
                                // not silent.
                                if let target = Windows.altTabFocusTarget,
                                   target.application.pid != ownerPid {
                                    Diagnostics.log("GUARD",
                                        "released by user click: clicked pid=\(ownerPid) (\(short.prefix(30))) ≠ target pid=\(target.application.pid)")
                                    Windows.altTabFocusTarget = nil
                                    Windows.altTabFocusTargetUntil = 0
                                    Windows.recentZOrderIntents.removeAll()
                                }
                            }
                            Diagnostics.log("MOUSE", "\(button) \(action) at (\(Int(cgPoint.x)),\(Int(cgPoint.y))) → wid=\(wid) pid=\(ownerPid) \(short)")
                            // CLICKMISROUTE: when the click resolved to a wid that
                            // is NOT our most recent AltTab focus target, the user
                            // likely clicked expecting the target window but hit
                            // something else (a stealer at z0, a bouncing sibling,
                            // or just stale focus). We suppress when there's no
                            // recent target (>5s since last focus call) so plain
                            // user-clicking on whatever isn't flagged as misroute.
                            if isDown,
                               let recentTarget = App.lastFocusedTargetWid,
                               let recentTargetTime = App.lastFocusedTargetTime,
                               CFAbsoluteTimeGetCurrent() - recentTargetTime < 5.0,
                               CGWindowID(wid) != recentTarget {
                                let ageMs = Int((CFAbsoluteTimeGetCurrent() - recentTargetTime) * 1000)
                                let recentTargetPid = App.lastFocusedTargetPid ?? 0
                                let isAppMismatch = (recentTargetPid != 0 && ownerPid != recentTargetPid)
                                let kind = isAppMismatch ? "APP-MISMATCH" : "WINDOW-MISMATCH"
                                Diagnostics.log("CLICKMISROUTE",
                                    "[\(kind)] click→wid=\(wid) pid=\(ownerPid) (\(short.prefix(40))) but AltTab target wid=\(recentTarget) pid=\(recentTargetPid) (\(ageMs)ms ago)")
                            }
                            // CLICKAFTER: schedule a +200ms probe of where
                            // input is actually routed. If frontmost-app's
                            // pid differs from the click's pid at +200ms,
                            // the user's typing in the next ~hundred-ms
                            // would land in the wrong app. This is the
                            // diagnostic that catches "I clicked OneNote
                            // but my keystrokes go to Safari" — clicks
                            // resolve correctly via WindowServer, but a
                            // background app self-activation between
                            // click and keystroke routes input elsewhere.
                            if isDown {
                                let clickedWid = CGWindowID(wid)
                                let clickedPid = ownerPid
                                let clickedShort = short
                                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
                                    let nsApp = NSWorkspace.shared.frontmostApplication
                                    let frontPid = nsApp?.processIdentifier ?? -1
                                    let frontName = nsApp?.localizedName ?? "?"
                                    var axFocusedWid: CGWindowID = 0
                                    if frontPid > 0 {
                                        let appRef = AXUIElementCreateApplication(frontPid)
                                        var focusedValue: AnyObject?
                                        if AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
                                           let windowRef = focusedValue {
                                            var w: CGWindowID = 0
                                            if _AXUIElementGetWindow(windowRef as! AXUIElement, &w) == .success {
                                                axFocusedWid = w
                                            }
                                        }
                                    }
                                    if frontPid != clickedPid {
                                        Diagnostics.log("CLICKAFTER",
                                            "+200ms after click on wid=\(clickedWid) pid=\(clickedPid) (\(clickedShort.prefix(30))) → frontmost is pid=\(frontPid) \(frontName) axFoc=#\(axFocusedWid). Input would route to a DIFFERENT app than the user clicked.")
                                    }
                                }
                            }
                            break
                        }
                    }
                } else {
                    Diagnostics.log("MOUSE", "\(button) \(action) at (\(Int(cgPoint.x)),\(Int(cgPoint.y)))")
                }
            }
        }
        AXUIElement.setGlobalTimeout()
        Preferences.initialize()
        BackgroundWork.preStart()
        SystemPermissions.ensurePermissionsAreGranted()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        App.showSettingsWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // symbolic hotkeys state persist after the app is quit; we restore this shortcut before quitting
        setNativeCommandTabEnabled(true)
        // Tell the Windows-side helper to terminate so we don't leave a
        // dangling TCP listener when AltTab quits.
        Winside.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Logger.info { "" }
        makeSureAllCapturesAreFinished()
        return .terminateNow
    }
}

enum RefreshCausedBy {
    case refreshOnlyThumbnailsAfterShowUi
    case refreshUiAfterExternalEvent
}
