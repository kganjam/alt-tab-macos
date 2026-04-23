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

    static func restart() {
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
        appIsBeingUsed = false
        // note: `sessionSourcePid` is intentionally NOT cleared here because
        // `focusSelectedWindow` calls `hideUi(true)` immediately BEFORE
        // `window.focus()`, and the focus path still needs the source pid to
        // detect Parallels Coherence outbound switches. The pid is overwritten
        // on the next session start in `showUiOrCycleSelection`.
        isFirstSummon = true
        forceDoNothingOnRelease = false
        UsageStats.resetSession()
        TilesView.endSearchSession()
        ContextMenuEvents.toggle(false)
        CursorEvents.toggle(false)
        TrackpadEvents.reset()
        hideTilesPanelWithoutChangingKeyWindow()
        if !keepPreview {
            PreviewPanel.shared.orderOut(nil)
        }
        hideAllTooltips()
        MainMenu.toggle(true)
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

    private static func updateParallelsMenuStates() {
        guard let parallelsItem = Menubar.menu.items.first(where: { $0.title == "Parallels Mode" }),
              let sub = parallelsItem.submenu else { return }
        for item in sub.items {
            switch item.title {
            case "Enable Overlay Mode": item.state = FocusOverlay.overlayModeEnabled ? .on : .off
            case "Hide Source Window": item.state = UserDefaults.standard.bool(forKey: "hideSourceWindow") ? .on : .off
            case "Coherence Thumbnails": item.state = !UserDefaults.standard.bool(forKey: "disableCoherencePreviews") ? .on : .off
            case "Diagnostics Logging": item.state = Diagnostics.enabled ? .on : .off
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
                window.focus()
                if Preferences.cursorFollowFocus == .always || (
                    Preferences.cursorFollowFocus == .differentScreen && (Spaces.screenSpacesMap.first { $0.value.contains { space in window.spaceIds.contains(space) } })?.key != NSScreen.active()?.cachedUuid()) {
                    moveCursorToSelectedWindow(window)
                }
            } else {
                PreviewPanel.shared.orderOut(nil)
            }
            // Delay panel dismiss — target is now raising under the curtain
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
                hideUi(true)
            }
        } else {
            // Non-Parallels: original order
            hideUi(true)
            if let window = selectedWindow, MissionControl.state() == .inactive || MissionControl.state() == .showDesktop {
                window.focus()
                if Preferences.cursorFollowFocus == .always || (
                    Preferences.cursorFollowFocus == .differentScreen && (Spaces.screenSpacesMap.first { $0.value.contains { space in window.spaceIds.contains(space) } })?.key != NSScreen.active()?.cachedUuid()) {
                    moveCursorToSelectedWindow(window)
                }
            } else {
                PreviewPanel.shared.orderOut(nil)
            }
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
        App.appCenterDelegate = AppCenterCrash()
        App.shared.disableRelaunchOnLogin()
        Logger.initialize()
        Logger.info { "Launching AltTab \(App.version)" }
        Diagnostics.log("INIT", "AltTab \(App.version) launched (custom build with diagnostics)")
        Diagnostics.startContinuousMonitoring()
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
                        let short = name.isEmpty ? owner : "\(owner):\(name.prefix(30))"
                        Diagnostics.log("MOUSE", "\(button) \(action) at (\(Int(cgPoint.x)),\(Int(cgPoint.y))) → wid=\(wid) \(short)")
                        break
                    }
                }
            } else {
                Diagnostics.log("MOUSE", "\(button) \(action) at (\(Int(cgPoint.x)),\(Int(cgPoint.y)))")
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
