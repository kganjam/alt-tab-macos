import Cocoa

class Windows {
    static var list = [Window]()
    static var selectedWindowIndex = Int(0)
    static var selectedWindowTarget: String?
    static var hoveredWindowIndex: Int?
    // we use this to track if the focused window changed while alt-tab was open
    private static var lastFocusedWindowTarget: String?
    /// When AltTab initiates a focus change via SLPS + pin for a Parallels
    /// transition, Cocoa often fires a brief spurious `kAXFocusedWindowChanged`
    /// notification for the target app's PREVIOUSLY-key window before
    /// settling on our actual target. If we let that event through to
    /// `updateLastFocusOrder`, the recency list gets a stale window
    /// promoted to position 0, and a user alternating A↔B can end up
    /// with C (a third window) being offered as the next target.
    ///
    /// `altTabFocusTarget` is set to the target window for the duration
    /// of `altTabFocusGuardMs` milliseconds. During that window,
    /// `AccessibilityEvents.focusedWindowChanged` suppresses recency
    /// updates for any window OTHER than this target.
    static var altTabFocusTarget: Window?
    static var altTabFocusTargetUntil: CFAbsoluteTime = 0
    // Guard must cover: Parallels' timer-driven re-activation (~500-1500ms),
    // our RERAISE at 400/700/1000ms, AND the source-hide duration (3s).
    // User clicks are detected via mouse monitor and bypass the guard.
    static let altTabFocusGuardMs: Double = 3000
    /// Bumped on every Parallels-involved focus transition. Delayed
    /// snapshot-restore blocks check this and skip if a newer transition
    /// has started, so a late restore can't clobber the user's latest
    /// state.
    static var parallelsTransitionGeneration: UInt64 = 0

    /// Called at AltTab session start. Deterministically sets recency so
    /// position 0 is the current frontmost window and position 1 is the
    /// PREVIOUS session's source window (the window the user was on
    /// before switching to the current one). Everything else is re-indexed
    /// to 2, 3, … preserving relative recency. This ensures the switcher
    /// always shows [current, previous, …] regardless of any spurious
    /// AX events that may have drifted the list between sessions.
    static func normalizeFocusOrderAtSessionStart(currentWid: CGWindowID?, previousWid: CGWindowID?) {
        guard let currentWid,
              let currentWindow = (list.first { $0.cgWindowId == currentWid }) else { return }
        let previousWindow: Window? = {
            guard let previousWid, previousWid != currentWid else { return nil }
            return list.first { $0.cgWindowId == previousWid }
        }()
        setTargetAndSourceAsMostRecent(target: currentWindow, source: previousWindow)
    }

    /// Set `target` to lastFocusOrder 0 AND `source` (if provided) to 1,
    /// with all other windows shifted to 2, 3, … preserving their
    /// relative recency. Used for Parallels-involved transitions where
    /// ordinary `updateLastFocusOrder(target)` can leave a corrupted
    /// window at position 1 (if a spurious AX event had previously
    /// promoted it). Making the ordering deterministic from the known
    /// source+target is more robust than trusting the prior list state.
    static func setTargetAndSourceAsMostRecent(target: Window, source: Window?) {
        let others = list.filter { $0 !== target && $0 !== source }
            .sorted { $0.lastFocusOrder < $1.lastFocusOrder }
        target.lastFocusOrder = 0
        var nextOrder = 1
        if let source {
            source.lastFocusOrder = nextOrder
            nextOrder += 1
        }
        for w in others {
            w.lastFocusOrder = nextOrder
            nextOrder += 1
        }
    }

    /// Recent focus targets with intended z-order. The guard periodically
    /// verifies actual z-order matches intent and re-raises if needed.
    struct ZOrderIntent {
        let wid: CGWindowID
        let pid: pid_t
        let timestamp: CFAbsoluteTime
        weak var window: Window?
        var raiseAttempts: Int = 0
        var wasEverAtZ0: Bool = false
        static let maxRaiseAttempts = 6
    }
    static var recentZOrderIntents = [ZOrderIntent]()
    private static var zOrderEnforcementTimer: DispatchSourceTimer?
    private static var zOrderEnforcementGeneration: UInt64 = 0

    static func armAltTabFocusGuard(for target: Window) {
        altTabFocusTarget = target
        altTabFocusTargetUntil = CFAbsoluteTimeGetCurrent() + altTabFocusGuardMs / 1000.0
        counterRaiseCount = 0
        // Record this target's intended z-position (topmost)
        if let wid = target.cgWindowId {
            let now = CFAbsoluteTimeGetCurrent()
            // Prune entries older than 5s
            recentZOrderIntents.removeAll { now - $0.timestamp > 3.0 }
            // Remove prior entry for same wid (update timestamp)
            recentZOrderIntents.removeAll { $0.wid == wid }
            recentZOrderIntents.append(ZOrderIntent(
                wid: wid, pid: target.application.pid,
                timestamp: now, window: target))
            startZOrderEnforcement()
        }
    }

    /// Poll actual z-order every 500ms for 5s after last focus target.
    /// If the most recent target isn't at z0 among app windows, re-raise.
    private static func startZOrderEnforcement() {
        zOrderEnforcementTimer?.cancel()
        zOrderEnforcementGeneration &+= 1
        let myGen = zOrderEnforcementGeneration
        Diagnostics.log("ZENFORCE", "starting timer gen=\(myGen), \(recentZOrderIntents.count) intents")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // First check at +100ms, then every 200ms. Parallels re-orders
        // at ~400ms — we need to catch and correct within that window.
        // Each check is one CGWindowListCopyWindowInfo + potential AX raise.
        timer.schedule(deadline: .now() + .milliseconds(100),
                       repeating: .milliseconds(200))
        timer.setEventHandler {
            guard zOrderEnforcementGeneration == myGen else { return }
            let now = CFAbsoluteTimeGetCurrent()
            recentZOrderIntents.removeAll { now - $0.timestamp > 3.0 }
            guard !recentZOrderIntents.isEmpty else {
                Diagnostics.log("ZENFORCE", "no intents left, stopping timer")
                zOrderEnforcementTimer?.cancel()
                zOrderEnforcementTimer = nil
                return
            }
            enforceZOrder()
        }
        timer.resume()
        zOrderEnforcementTimer = timer
        // Auto-stop after 3s (aligned with focus guard duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard zOrderEnforcementGeneration == myGen else { return }
            Diagnostics.log("ZENFORCE", "5s auto-stop gen=\(myGen)")
            zOrderEnforcementTimer?.cancel()
            zOrderEnforcementTimer = nil
        }
    }

    /// Check that the most recent target is at z0 in the actual window
    /// list. If not, use CGSOrderWindow to directly reorder it without
    /// process-level activation side effects.
    private static func enforceZOrder() {
        guard let mostRecent = recentZOrderIntents.last,
              let window = mostRecent.window else { return }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }
        let blocklist: Set<String> = [
            "Window Server", "Control Center", "Dock", "AltTab",
            "Notification Center", "SystemUIServer", "Spotlight",
            "Menubar", "Wallpaper", "CursorUIViewService",
            "LocalAuthenticationRemoteService",
        ]
        var targetZPos = -1
        var sameAppDialogAbove = false
        var pos = 0
        var topWids = [(Int, String)]() // for logging
        for w in info {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            if blocklist.contains(owner) { continue }
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha < 0.1 { continue }
            if let bounds = w[kCGWindowBounds as String] as? [String: Any],
               let width = bounds["Width"] as? Double, width < 40 { continue }
            let wid = (w[kCGWindowNumber as String] as? Int) ?? 0
            let name = (w[kCGWindowName as String] as? String) ?? ""
            if pos < 4 { topWids.append((wid, "\(owner.prefix(8)):\(name.prefix(15))")) }
            if CGWindowID(wid) == mostRecent.wid {
                targetZPos = pos
                break
            }
            // If a same-pid window above the target is NOT tracked in
            // Windows.list, it's a genuinely new window (dialog, popup,
            // confirmation). Don't push it behind the target.
            let ownerPid = (w[kCGWindowOwnerPID as String] as? Int32) ?? 0
            let aboveWid = CGWindowID(wid)
            if ownerPid == mostRecent.pid {
                let isTracked = list.contains { $0.cgWindowId == aboveWid }
                if !isTracked {
                    sameAppDialogAbove = true
                    let name = (w[kCGWindowName as String] as? String) ?? ""
                    Diagnostics.log("ZENFORCE", "untracked same-app wid=\(aboveWid) \(owner):\(name.prefix(20)) above target — dialog?")
                }
            }
            pos += 1
        }
        let zSummary = topWids.enumerated().map { "z\($0.0)=#\($0.1.0) \($0.1.1)" }.joined(separator: " | ")
        Diagnostics.log("ZENFORCE", "target=\(mostRecent.wid) at z\(targetZPos) [\(zSummary)]")
        if targetZPos == 0 {
            if !mostRecent.wasEverAtZ0 {
                recentZOrderIntents[recentZOrderIntents.count - 1].wasEverAtZ0 = true
                recentZOrderIntents[recentZOrderIntents.count - 1].raiseAttempts = 0
            }
        } else if targetZPos > 0 && sameAppDialogAbove {
            // Untracked same-app window above target — likely a dialog.
            // Don't push it behind.
            Diagnostics.log("ZENFORCE", "wid=\(mostRecent.wid) at z\(targetZPos) — untracked same-app dialog above, skipping")
        } else if targetZPos > 0 {
            guard mostRecent.raiseAttempts < ZOrderIntent.maxRaiseAttempts else {
                Diagnostics.log("ZENFORCE", "wid=\(mostRecent.wid) at z\(targetZPos), max \(ZOrderIntent.maxRaiseAttempts) attempts — stopping")
                recentZOrderIntents.removeAll()
                return
            }
            recentZOrderIntents[recentZOrderIntents.count - 1].raiseAttempts += 1
            let attempt = recentZOrderIntents[recentZOrderIntents.count - 1].raiseAttempts
            let err = CGSOrderWindow(CGS_CONNECTION, mostRecent.wid,
                                     CGSWindowOrderingMode.above.rawValue, 0)
            if err == .success {
                Diagnostics.log("ZENFORCE", "CGSOrderWindow(wid=\(mostRecent.wid)) fixed z\(targetZPos)→z0")
            } else {
                Diagnostics.log("ZENFORCE", "wid=\(mostRecent.wid) at z\(targetZPos), AX raise #\(attempt)/\(ZOrderIntent.maxRaiseAttempts)")
                try? window.axUiElement?.performAction(kAXRaiseAction as String)
            }
        } else {
            Diagnostics.log("ZENFORCE", "wid=\(mostRecent.wid) not found in z-order (offscreen?)")
        }
    }

    /// Restore the correct z-order after a Parallels window close. macOS
    /// raises a random same-process window; we override by raising the top
    /// windows from our recency list in reverse order (so position 0 ends
    /// up on top). Query actual z-order first to only raise windows that
    /// are out of position.
    static func restoreZOrderFromRecency() {
        let topWindows = list
            .sorted { $0.lastFocusOrder < $1.lastFocusOrder }
            .prefix(5)
            .compactMap { w -> (Window, CGWindowID)? in
                guard let wid = w.cgWindowId else { return nil }
                return (w, wid)
            }
        guard !topWindows.isEmpty else { return }

        // Query actual z-order to find what's out of place
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let blocklist: Set<String> = [
            "Window Server", "Control Center", "Dock", "AltTab",
            "Notification Center", "SystemUIServer", "Spotlight",
            "Menubar", "Wallpaper", "CursorUIViewService",
            "LocalAuthenticationRemoteService",
        ]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }
        var actualZOrder = [CGWindowID]()
        for w in info {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            if blocklist.contains(owner) { continue }
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha < 0.1 { continue }
            if let bounds = w[kCGWindowBounds as String] as? [String: Any],
               let width = bounds["Width"] as? Double, width < 40 { continue }
            let wid = CGWindowID((w[kCGWindowNumber as String] as? Int) ?? 0)
            actualZOrder.append(wid)
        }

        // Raise top recency windows in REVERSE order so #0 ends up on top.
        // Only raise if the window is out of position (lower in z than expected).
        let topWid = topWindows[0].1
        let topZPos = actualZOrder.firstIndex(of: topWid) ?? Int.max
        if topZPos == 0 {
            Diagnostics.log("ZRESTORE", "top window wid=\(topWid) already at z0, no restore needed")
            return
        }

        Diagnostics.log("ZRESTORE", "restoring z-order: top recency wid=\(topWid) at z\(topZPos)")

        // Try CGSOrderWindow to set exact z-order. Place each window
        // above the one that should be below it, working from bottom up.
        // This builds the correct stack: position 2 at bottom, 1 above it, 0 on top.
        var lastPlacedWid: CGWindowID = 0
        var cgsWorked = false
        for (_, wid) in topWindows.reversed() {
            guard actualZOrder.contains(wid) else { continue }
            if lastPlacedWid == 0 {
                // First window — place at top of z-order
                let err = CGSOrderWindow(CGS_CONNECTION, wid, CGSWindowOrderingMode.above.rawValue, 0)
                Diagnostics.log("ZRESTORE", "CGSOrderWindow(wid=\(wid), above, 0) → \(err.rawValue)")
                if err == .success { cgsWorked = true }
            } else {
                // Place above the previously placed window
                let err = CGSOrderWindow(CGS_CONNECTION, wid, CGSWindowOrderingMode.above.rawValue, lastPlacedWid)
                Diagnostics.log("ZRESTORE", "CGSOrderWindow(wid=\(wid), above, \(lastPlacedWid)) → \(err.rawValue)")
                if err == .success { cgsWorked = true }
            }
            lastPlacedWid = wid
        }

        // If CGSOrderWindow failed (err 1000), fall back to AX raise
        // in reverse order (position 2, then 1, then 0).
        if !cgsWorked {
            Diagnostics.log("ZRESTORE", "CGSOrderWindow failed, falling back to AX raise")
            for (window, wid) in topWindows.reversed() {
                guard actualZOrder.contains(wid) else { continue }
                try? window.axUiElement?.performAction(kAXRaiseAction as String)
            }
        }

        // Activate the top window SYNCHRONOUSLY via SLPS before Parallels
        // can raise its own window. Also AX raise immediately.
        let (topWindow, _) = topWindows[0]
        var psn = ProcessSerialNumber()
        GetProcessForPID(topWindow.application.pid, &psn)
        if let wid = topWindow.cgWindowId {
            _SLPSSetFrontProcessWithOptions(&psn, wid, SLPSMode.userGenerated.rawValue)
            topWindow.makeKeyWindow(&psn)
            try? topWindow.axUiElement?.focusWindow()
            Diagnostics.log("ZRESTORE", "SLPS + makeKeyWindow + AX raise for top wid=\(wid) \(topWindow.debugId ?? "?")")
        }
    }

    /// Clear the guard at the start of each new focus() call so a 2-second
    /// guard left over from a prior Parallels transition can't silently
    /// suppress legitimate focus events from a subsequent macOS→macOS
    /// switch. The Parallels focus paths re-arm the guard themselves
    /// when they need it; the standard SLPS path doesn't — leaving it
    /// cleared is the correct default.
    ///
    /// ALSO bumps `parallelsTransitionGeneration` so any pending delayed
    /// snapshot-restore block from a prior Parallels transition becomes
    /// stale and is skipped. Without this, a Par→A restore scheduled at
    /// t+500ms would fire after the user has mac→B-switched, restoring
    /// the pre-Par state and demoting B out of position 0.
    static func clearAltTabFocusGuard() {
        altTabFocusTarget = nil
        altTabFocusTargetUntil = 0
        parallelsTransitionGeneration &+= 1
        // Stop z-order enforcement — a new focus() call means the user
        // switched to a different window; enforcing the old target's
        // z-position would fight the user's intent.
        recentZOrderIntents.removeAll()
        zOrderEnforcementGeneration &+= 1
        zOrderEnforcementTimer?.cancel()
        zOrderEnforcementTimer = nil
    }

    static func shouldSuppressFocusOrderUpdate(for window: Window) -> Bool {
        guard CFAbsoluteTimeGetCurrent() < altTabFocusTargetUntil,
              let target = altTabFocusTarget else { return false }
        return window !== target
    }

    /// Same guard semantics as `shouldSuppressFocusOrderUpdate` but
    /// checks app-level (for `kAXApplicationActivatedNotification`
    /// events). Returns true if a Parallels-transition guard is armed
    /// and the activating app isn't the target's app.
    ///
    /// EVENT-DRIVEN COUNTER-RAISE: when this returns true, we also
    /// schedule an immediate re-raise of the target. This way,
    /// Parallels' timer-driven self-activation (which fires ~1s after
    /// our focus) is countered the moment it's detected — no timing
    /// guesswork needed. The re-raise runs on the background AX queue
    /// so AX IPC can't freeze main thread.
    static var counterRaiseCount = 0
    static let maxCounterRaises = 3
    /// Timestamp of the last global mouse click, used to distinguish
    /// user-initiated window activations from Parallels' automatic
    /// re-activation. Updated by the global event monitor installed
    /// at startup.
    static var lastMouseClickTime: CFAbsoluteTime = 0

    static func shouldSuppressApplicationActivation(for app: Application) -> Bool {
        guard CFAbsoluteTimeGetCurrent() < altTabFocusTargetUntil,
              let target = altTabFocusTarget else { return false }
        guard target.application.pid != app.pid else { return false }
        // If a mouse click happened recently, this is a user-initiated
        // activation — allow it through and clear the guard so subsequent
        // AX events from the clicked window also pass.
        let timeSinceClick = CFAbsoluteTimeGetCurrent() - lastMouseClickTime
        if timeSinceClick < 0.3 {
            Diagnostics.log("CLICK", "mouse click detected \(Int(timeSinceClick * 1000))ms ago, allowing activation of pid=\(app.pid) \(app.bundleIdentifier ?? "?"), clearing guard")
            clearAltTabFocusGuard()
            return false
        }
        // Suppress ALL non-target activations during the guard, not just
        // Parallels. During rapid double alt-tabs, the FIRST target's
        // stale AXEVENT can arrive after we've switched to the second
        // target, corrupting frontmostPid. User clicks are already
        // handled above via the mouse click check.
        // Counter-raise only for Parallels (they actively fight back).
        if app.isParallelsCoherence, counterRaiseCount < maxCounterRaises {
            counterRaiseCount += 1
            Diagnostics.log("COUNTER", "Parallels stole front (attempt \(counterRaiseCount)/\(maxCounterRaises)), counter-raising \(target.debugId ?? "?")")
            // AX raise only — no activate() which raises ALL app windows.
            // ZENFORCE also enforces z-order independently.
            BackgroundWork.accessibilityCommandsQueue.addOperation { [weak target] in
                guard let target else { return }
                try? target.axUiElement?.focusWindow()
                Diagnostics.log("API", "COUNTER AX focusWindow done")
            }
        }
        return true
    }
    private static var lastWindowActivityType = WindowActivityType.none
    static var searchQuery = ""
    private static var shouldSelectBestMatchOnSearchChange = false
    private static var shouldRestoreDefaultSelectionOnSearchClear = false

    static func shouldDisplay(_ window: Window) -> Bool {
        window.shouldShowTheUser && Search.matches(window, query: searchQuery)
    }

    static func updateSearchQuery(_ query: String) {
        let previousTrimmedQuery = Search.normalizedQuery(searchQuery)
        let newTrimmedQuery = Search.normalizedQuery(query)
        searchQuery = query
        guard App.appIsBeingUsed else {
            shouldSelectBestMatchOnSearchChange = false
            shouldRestoreDefaultSelectionOnSearchClear = false
            sort()
            return
        }
        if previousTrimmedQuery != newTrimmedQuery {
            if newTrimmedQuery.isEmpty {
                shouldRestoreDefaultSelectionOnSearchClear = !previousTrimmedQuery.isEmpty
                shouldSelectBestMatchOnSearchChange = false
            } else {
                shouldSelectBestMatchOnSearchChange = true
                shouldRestoreDefaultSelectionOnSearchClear = false
                hoveredWindowIndex = nil
            }
        }
        sort()
    }

    static func updateIsFullscreenOnCurrentSpace() {
        let windowsOnCurrentSpace = list.filter { !$0.isWindowlessApp }
        for window in windowsOnCurrentSpace {
            guard let wid = window.cgWindowId, let axUiElement = window.axUiElement else { continue }
            AXCallScheduler.shared.schedule(key: "wid-\(wid)", context: window.debugId, pid: window.application.pid) { [weak window] in
                guard let window else { return }
                // we reuse existing code, to update .isFullscreen, as if there was a kAXWindowResizedNotification
                try AccessibilityEvents.handleEventWindow(kAXWindowResizedNotification, wid, window.application.pid, axUiElement)
            }
        }
    }

    private static func compareByAppNameThenWindowTitle(_ w1: Window, _ w2: Window) -> ComparisonResult {
        let order = w1.application.localizedName.localizedStandardCompare(w2.application.localizedName)
        if order == .orderedSame {
            return w1.title.localizedStandardCompare(w2.title)
        }
        return order
    }

    static func voiceOverWindow(_ windowIndex: Int = selectedWindowIndex) {
        guard App.appIsBeingUsed && TilesPanel.shared.isKeyWindow else { return }
        if TilesView.isSearchEditing { return }
        // it seems that sometimes makeFirstResponder is called before the view is visible
        // and it creates a delay in showing the main window; calling it with some delay seems to work around this
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
            if TilesView.isSearchEditing { return }
            let window = TilesView.recycledViews[windowIndex]
            if window.window_ != nil && window.window != nil {
                TilesPanel.shared.makeFirstResponder(window)
            }
        }
    }

    static func previewSelectedWindowIfNeeded() {
        if App.appIsBeingUsed && ScreenRecordingPermission.status == .granted
               && Preferences.previewSelectedWindow && !Preferences.onlyShowApplications()
               && TilesPanel.shared.isKeyWindow,
           let window = selectedWindow(),
           let id = window.cgWindowId,
           let thumbnail = window.thumbnail,
           let position = window.position,
           let size = window.size {
            PreviewPanel.show(id, thumbnail, position, size)
        } else {
            PreviewPanel.shared.orderOut(nil)
        }
    }

    static func updatesBeforeShowing() -> Bool {
        if MissionControl.state() == .showAllWindows || MissionControl.state() == .showFrontWindows { return false }
        if list.isEmpty { return true }
        // TODO: find a way to update space info when spaces are changed, instead of on every trigger
        // workaround: when Preferences > Mission Control > "Displays have separate Spaces" is unchecked,
        // switching between displays doesn't trigger .activeSpaceDidChangeNotification; we get the latest manually
        Spaces.refresh()
        for window in list {
            window.updateSpacesAndScreen()
            refreshIfWindowShouldBeShownToTheUser(window)
        }
        refreshWhichWindowsToShowTheUser()
        sort()
        return true
    }

    // dispatch screenshot requests off the main-thread, then wait for completion
    static func refreshThumbnailsAsync(_ windows: [Window], _ source: RefreshCausedBy, windowRemoved: Bool = false) {
        guard (!windows.isEmpty || windowRemoved) && ScreenRecordingPermission.status == .granted
               && !Preferences.onlyShowApplications()
               && (!Appearance.hideThumbnails || Preferences.previewSelectedWindow)
               && (Preferences.captureWindowsInBackground || App.appIsBeingUsed) else { return }
        let skipCoherencePreviews = UserDefaults.standard.bool(forKey: "disableCoherencePreviews")
        var eligibleWindows = [Window]()
        for window in windows {
            if !window.isWindowlessApp, let cgWindowId = window.cgWindowId, cgWindowId != CGWindowID(bitPattern: -1) {
                if skipCoherencePreviews && window.application.isParallelsCoherence { continue }
                eligibleWindows.append(window)
            }
        }
        guard (!eligibleWindows.isEmpty || windowRemoved) else { return }
        if #available(macOS 14.0, *),
           // mitigate macOS 15 bugs with ScreenCapture Kit (see https://github.com/lwouis/alt-tab-macos/issues/5190)
           ProcessInfo.processInfo.operatingSystemVersion.majorVersion != 15 {
            WindowCaptureScreenshots.oneTimeScreenshots(eligibleWindows, source)
        } else {
            WindowCaptureScreenshotsPrivateApi.oneTimeScreenshots(eligibleWindows, source)
        }
    }

    static func refreshWhichWindowsToShowTheUser() {
        if Preferences.onlyShowApplications() {
            // Group windows by application and select the optimal main window
            let windowsGroupedByApp = Dictionary(grouping: list) { $0.application.pid }
            windowsGroupedByApp.forEach { (app, windows) in
                if windows.count > 1, let mainWindow = findMainWindow(windows) {
                    windows.forEach { window in
                        if window.cgWindowId != mainWindow.cgWindowId {
                            window.shouldShowTheUser = false
                        }
                    }
                }
            }
        }
    }

    private static func shouldHideWindow(_ window: Window, _ entry: ExceptionEntry) -> Bool {
        switch entry.hide {
        case .none:
            return false
        case .always:
            return true
        case .whenNoOpenWindow:
            return window.isWindowlessApp
        case .windowTitleContains:
            guard let titleFilter = entry.windowTitleContains, !titleFilter.isEmpty else {
                return false
            }
            return window.title.contains(titleFilter)
        }
    }

    private static func refreshIfWindowShouldBeShownToTheUser(_ window: Window) {
        window.shouldShowTheUser =
            !(window.application.bundleIdentifier.flatMap { id in
                Preferences.exceptions.contains {
                    id.hasPrefix($0.bundleIdentifier) && shouldHideWindow(window, $0)
                }
            } ?? false) &&
            !(Preferences.appsToShow[App.shortcutIndex] == .active && window.application.pid != Applications.frontmostPid) &&
            !(Preferences.appsToShow[App.shortcutIndex] == .nonActive && window.application.pid == Applications.frontmostPid) &&
            !(!(Preferences.showHiddenWindows[App.shortcutIndex] != .hide) && window.isHidden) &&
            ((Preferences.showWindowlessApps[App.shortcutIndex] != .hide && window.isWindowlessApp) ||
                !window.isWindowlessApp &&
                !(!(Preferences.showFullscreenWindows[App.shortcutIndex] != .hide) && window.isFullscreen) &&
                !(!(Preferences.showMinimizedWindows[App.shortcutIndex] != .hide) && window.isMinimized) &&
                !(Preferences.spacesToShow[App.shortcutIndex] == .visible && !Spaces.visibleSpaces.contains { visibleSpace in window.spaceIds.contains { $0 == visibleSpace } }) &&
                !(Preferences.spacesToShow[App.shortcutIndex] == .nonVisible && Spaces.visibleSpaces.contains { visibleSpace in window.spaceIds.contains { $0 == visibleSpace } }) &&
                !(Preferences.screensToShow[App.shortcutIndex] == .showingAltTab && !window.isOnScreen(NSScreen.preferred)) &&
                (Preferences.showTabsAsWindows || !window.isTabbed))
    }

    /// Selects the most appropriate main window from a given list of windows.
    ///
    /// The selection criteria are as follows:
    /// 1. Prefer the focused window if it exists.
    /// 2. Prefer the main window of the application if the focused window is not found.
    ///
    /// - Parameter windows: An array of `Window` objects to select from.
    /// - Returns: The most appropriate `Window` object based on the selection criteria, or `nil` if the array is empty.
    static func findMainWindow(_ windows: [Window]) -> Window? {
        let sortedWindows = windows.sorted { (window1, window2) -> Bool in
            // Prefer the focus window
            if window1.application.focusedWindow?.cgWindowId == window1.cgWindowId {
                return true
            } else if window2.application.focusedWindow?.cgWindowId == window2.cgWindowId {
                return false
            }
            // Prefer the main window
            if window1.isAppMainWindow() && !window2.isAppMainWindow() {
                return true
            } else if !window1.isAppMainWindow() && window2.isAppMainWindow() {
                return false
            }
            return true
        }
        return sortedWindows.first { $0.shouldShowTheUser }
    }

    /// selectedWindowIndex methods
    //////////////////////////////

    static func selectedWindow() -> Window? {
        guard list.count > selectedWindowIndex else { return nil }
        let window = list[selectedWindowIndex]
        return shouldDisplay(window) ? window : nil
    }

    static func setInitialSelectedAndHoveredWindowIndex() {
        let oldIndex = selectedWindowIndex
        selectedWindowIndex = 0
        selectedWindowTarget = nil
        TilesView.highlight(oldIndex)
        if let oldIndex = hoveredWindowIndex {
            hoveredWindowIndex = nil
            TilesView.highlight(oldIndex)
        }
        if Applications.frontmostPid != nil,
           Preferences.windowOrder[App.shortcutIndex] != .recentlyFocused,
           let lastFocusedOrderWindowIndex = getLastFocusedOrderWindowIndex() {
            updateSelectedAndHoveredWindowIndex(lastFocusedOrderWindowIndex)
        } else {
            // edge-case: when the 2 most recently focused windows are both minimized, select the first
            if list.count >= 2 && list[0].isMinimized && list[1].isMinimized {
                updateSelectedAndHoveredWindowIndex(0)
            } else {
                cycleSelectedWindowIndex(1)
                if selectedWindowIndex == 0 {
                    updateSelectedAndHoveredWindowIndex(0)
                }
            }
        }
    }

    static func updateSelectedWindow() {
        let focusedWindowTarget = currentFocusedWindowTarget()
        defer { lastFocusedWindowTarget = focusedWindowTarget }
        if shouldRestoreDefaultSelectionOnSearchClear {
            shouldRestoreDefaultSelectionOnSearchClear = false
            setInitialSelectedAndHoveredWindowIndex()
            return
        }
        let visibleIndexes = visibleWindowIndexes()
        guard let firstVisibleIndex = visibleIndexes.first else {
            selectedWindowTarget = nil
            hoveredWindowIndex = nil
            return
        }
        if shouldSelectBestMatchOnSearchChange {
            shouldSelectBestMatchOnSearchChange = false
            updateSelectedAndHoveredWindowIndex(firstVisibleIndex)
            return
        }
        if shouldSelectFromScratch(focusedWindowTarget) {
            setInitialSelectedAndHoveredWindowIndex()
            return
        }
        if restoreSelectionTargetIfVisible() { return }
        adaptSelectionToVisibleIndexes(visibleIndexes, firstVisibleIndex)
    }

    private static func visibleWindowIndexes() -> [Int] {
        list.indices.filter { shouldDisplay(list[$0]) }
    }

    private static func currentFocusedWindowTarget() -> String? {
        getLastFocusedOrderWindowIndex().map { list[$0].id }
    }

    private static func shouldSelectFromScratch(_ focusedWindowTarget: String?) -> Bool {
        selectedWindowTarget == nil || focusedWindowChangedWhileShowing(focusedWindowTarget)
    }

    private static func focusedWindowChangedWhileShowing(_ focusedWindowTarget: String?) -> Bool {
        guard App.appIsBeingUsed, Search.normalizedQuery(searchQuery).isEmpty else { return false }
        guard let lastFocusedWindowTarget, let focusedWindowTarget else { return false }
        return focusedWindowTarget != lastFocusedWindowTarget
    }

    private static func restoreSelectionTargetIfVisible() -> Bool {
        guard let selectedWindowTarget else { return false }
        guard let index = list.firstIndex(where: { $0.id == selectedWindowTarget && shouldDisplay($0) }) else { return false }
        if index == selectedWindowIndex { return true }
        updateSelectedAndHoveredWindowIndex(index)
        return true
    }

    private static func adaptSelectionToVisibleIndexes(_ visibleIndexes: [Int], _ firstVisibleIndex: Int) {
        guard let lastVisibleIndex = visibleIndexes.last else { return }
        if !visibleIndexes.contains(selectedWindowIndex) {
            let closest = visibleIndexes.last(where: { $0 < selectedWindowIndex }) ?? lastVisibleIndex
            updateSelectedAndHoveredWindowIndex(closest)
            return
        }
        if selectedWindowIndex > lastVisibleIndex {
            updateSelectedAndHoveredWindowIndex(lastVisibleIndex)
            return
        }
        if selectedWindowIndex < firstVisibleIndex {
            updateSelectedAndHoveredWindowIndex(firstVisibleIndex)
            return
        }
        if selectedWindowTarget == nil {
            selectedWindowTarget = list[selectedWindowIndex].id
        }
    }

    static func updateSelectedAndHoveredWindowIndex(_ newIndex: Int, _ fromMouse: Bool = false) {
        guard newIndex >= 0 && newIndex < list.count else { return }
        guard shouldDisplay(list[newIndex]) else { return }
        var index: Int?
        if fromMouse && (newIndex != hoveredWindowIndex || lastWindowActivityType == .focus) {
            let oldIndex = hoveredWindowIndex
            hoveredWindowIndex = newIndex
            if let oldIndex {
                TilesView.highlight(oldIndex)
            }
            index = hoveredWindowIndex
            lastWindowActivityType = .hover
        }
        if !fromMouse {
            TilesView.thumbnailOverView.resetHoveredWindow()
        }
        if (!fromMouse || Preferences.mouseHoverEnabled)
               && (newIndex != selectedWindowIndex || lastWindowActivityType == .hover) {
            let oldIndex = selectedWindowIndex
            selectedWindowIndex = newIndex
            selectedWindowTarget = list[newIndex].id
            TilesView.highlight(oldIndex)
            previewSelectedWindowIfNeeded()
            index = selectedWindowIndex
            lastWindowActivityType = .focus
        }
        guard let index else { return }
        TilesView.highlight(index)
        let focusedView = TilesView.recycledViews[index]
        TilesView.scrollView.contentView.scrollToVisible(focusedView.frame)
        voiceOverWindow(index)
    }

    static func cycleSelectedWindowIndex(_ step: Int, allowWrap: Bool = true) {
        guard App.appIsBeingUsed else { return }
        guard list.contains(where: { shouldDisplay($0) }) else { return }
        let nextIndex = selectedWindowIndexAfterCycling(step)
        // don't wrap-around at the end, if key-repeat
        if (((step > 0 && nextIndex < selectedWindowIndex) || (step < 0 && nextIndex > selectedWindowIndex)) &&
            (!allowWrap || ATShortcut.lastEventIsARepeat || !KeyRepeatTimer.timerIsSuspended))
               // don't cycle to another row, if !allowWrap
               || (!allowWrap && list[nextIndex].rowIndex != list[selectedWindowIndex].rowIndex) {
            return
        }
        updateSelectedAndHoveredWindowIndex(nextIndex)
        // Pre-capture the newly selected window for the overlay
        if let window = selectedWindow(),
           let wid = window.cgWindowId,
           let pos = window.position, let sz = window.size {
            if #available(macOS 14.0, *) {
                FocusOverlay.preCapture(wid: wid, position: pos, size: sz)
            }
        }
    }

    static func selectedWindowIndexAfterCycling(_ step: Int) -> Int {
        if list.count == 0 || !list.contains(where: { shouldDisplay($0) }) { return selectedWindowIndex }
        var iterations = 0
        var targetIndex = selectedWindowIndex
        repeat {
            let next = (targetIndex + step) % list.count
            targetIndex = next < 0 ? list.count + next : next
            iterations += 1
        } while !shouldDisplay(list[targetIndex]) && iterations <= list.count
        return targetIndex
    }

    /// lastFocusOrder methods
    //////////////////////////////

    /// Updates windows "lastFocusOrder" to ensure unique values based on window z-order.
    /// Windows are ordered by their position in Spaces.windowsInSpaces() results,
    /// with topmost windows first.
    static func sortByLevel() {
        var windowLevelMap = [CGWindowID?: Int]()
        for (index, cgWindowId) in Spaces.windowsInSpaces(Spaces.visibleSpaces).enumerated() {
            windowLevelMap[cgWindowId] = index
        }
        list = list
        .sorted { w1, w2 in
            (windowLevelMap[w1.cgWindowId] ?? .max) < (windowLevelMap[w2.cgWindowId] ?? .max)
        }
        .enumerated()
        .map { (index, window) -> Window in
            window.lastFocusOrder = index
            return window
        }
    }

    /// reordered list based on preferences, keeping the original index
    private static func sort() {
        let trimmedQuery = Search.normalizedQuery(searchQuery)
        list.sort {
            if !trimmedQuery.isEmpty {
                let matches0 = Search.matches($0, query: trimmedQuery)
                let matches1 = Search.matches($1, query: trimmedQuery)
                if matches0 != matches1 { return matches0 }
                let score0 = Search.relevance(for: $0, query: trimmedQuery)
                let score1 = Search.relevance(for: $1, query: trimmedQuery)
                if score0 != score1 { return score0 > score1 }
                return $0.lastFocusOrder < $1.lastFocusOrder
            }
            // separate buckets for these types of windows
            if Preferences.showWindowlessApps[App.shortcutIndex] == .showAtTheEnd && $0.isWindowlessApp != $1.isWindowlessApp {
                return $1.isWindowlessApp
            }
            if Preferences.showHiddenWindows[App.shortcutIndex] == .showAtTheEnd && $0.isHidden != $1.isHidden {
                return $1.isHidden
            }
            if Preferences.showMinimizedWindows[App.shortcutIndex] == .showAtTheEnd && $0.isMinimized != $1.isMinimized {
                return $1.isMinimized
            }
            // sort within each buckets
            let sortType = Preferences.windowOrder[App.shortcutIndex]
            if sortType == .recentlyFocused {
                return $0.lastFocusOrder < $1.lastFocusOrder
            }
            if sortType == .recentlyCreated {
                return $1.creationOrder < $0.creationOrder
            }
            var order = ComparisonResult.orderedSame
            if sortType == .alphabetical {
                order = compareByAppNameThenWindowTitle($0, $1)
            }
            if sortType == .space {
                if $0.isOnAllSpaces && $1.isOnAllSpaces {
                    order = .orderedSame
                } else if $0.isOnAllSpaces {
                    order = .orderedAscending
                } else if $1.isOnAllSpaces {
                    order = .orderedDescending
                } else if let spaceIndex0 = $0.spaceIndexes.first, let spaceIndex1 = $1.spaceIndexes.first {
                    order = spaceIndex0.compare(spaceIndex1)
                }
                if order == .orderedSame {
                    order = compareByAppNameThenWindowTitle($0, $1)
                }
            }
            if order == .orderedSame {
                order = $0.lastFocusOrder.compare($1.lastFocusOrder)
            }
            return order == .orderedAscending
        }
    }

    static func getLastFocusedOrderWindowIndex() -> Int? {
        var index: Int? = nil
        var lastFocusOrderMin = Int.max
        for (offset, w) in list.enumerated() {
            if !w.isWindowlessApp && shouldDisplay(w) && w.lastFocusOrder < lastFocusOrderMin {
                lastFocusOrderMin = w.lastFocusOrder
                index = offset
            }
        }
        return index
    }

    static func updateLastFocusOrder(_ focusedWindow: Window) -> [Window]? {
        // no need to update the list is the window is already lastFocusOrder 0
        guard focusedWindow.lastFocusOrder != 0 && list.count > 1, let previousFocus = (list.first { $0.lastFocusOrder == 0 }) else { return [focusedWindow] }
        // 2 windows have recently changed: the one which got focused, and the one who just lost focus
        let windowsToRefresh = [focusedWindow, previousFocus]
        let focusedWindowOldFocusOrder = focusedWindow.lastFocusOrder
        list.forEach {
            if $0.lastFocusOrder == focusedWindowOldFocusOrder {
                $0.lastFocusOrder = 0
            } else if $0.lastFocusOrder < focusedWindowOldFocusOrder {
                $0.lastFocusOrder += 1
            }
        }
        return windowsToRefresh
    }

    static func findOrCreate(_ windowAxUiElement: AXUIElement, _ wid: CGWindowID, _ app: Application, _ level: CGWindowLevel, _ title: String?, _ subrole: String?, _ role: String?, _ size: CGSize?, _ position: CGPoint?, _ isFullscreen: Bool?, _ isMinimized: Bool?) -> (Window?, Bool) {
        if let window = (list.first { $0.isEqualRobust(windowAxUiElement, wid) }) {
            // on any window event, we take the opportunity to refresh all window attributes
            window.updateFromAxAttributes(title, size, position, isFullscreen, isMinimized)
            return (window, false)
        }
        guard WindowDiscriminator.isActualWindow(app, wid, level, title, subrole, role, size) else { return (nil, false) }
        let window = Window(windowAxUiElement, app, wid, title, isFullscreen, isMinimized, position, size)
        appendWindow(window)
        return (window, true)
    }

    static func appendWindow(_ window: Window) {
        window.lastFocusOrder = list.count
        list.append(window)
        if list.count > TilesView.recycledViews.count {
            TilesView.recycledViews.append(TileView())
        }
    }

    static func removeWindows(_ windows: [Window], _ addWindowlessWindowIfNeeded: Bool) {
        for w in windows {
            if w.application.focusedWindow?.cgWindowId == w.cgWindowId {
                w.application.focusedWindow = nil
            }
        }
        let toRemove = windows.map { $0.lastFocusOrder }
        list.removeAll { w in
            if toRemove.contains(w.lastFocusOrder) {
                return true
            }
            let howManyToShift = toRemove.reduce(0) { $1 < w.lastFocusOrder ? $0 + 1 : $0 }
            w.lastFocusOrder -= howManyToShift
            return false
        }
        for w in windows {
            if let wid = w.cgWindowId {
                AXCallScheduler.shared.removeEntry(key: "wid-\(wid)")
                Applications.windowListUpdateThrottler.removeEntry(withKey: "\(wid)")
            }
            // when a tabbed window is removed, update its former siblings' tab group
            if let siblingWids = w.tabbedSiblingWids {
                TabGroup.removedWindowFromGroup(wid: w.cgWindowId, siblingWids: siblingWids)
            }
        }
        if addWindowlessWindowIfNeeded {
            windows.forEach { $0.application.addWindowlessWindowIfNeeded() }
        }
        lastFocusedWindowTarget = getLastFocusedOrderWindowIndex().map { list[$0].id }
        App.refreshOpenUiAfterExternalEvent([], windowRemoved: true)
    }
}

enum WindowActivityType: Int {
    case none = 0
    case hover = 1
    case focus = 2
}
