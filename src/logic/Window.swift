import Cocoa

class Window {
    private static let notifications = [
        kAXUIElementDestroyedNotification,
        kAXTitleChangedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXWindowResizedNotification,
        kAXWindowMovedNotification,
    ]
    private static var globalCreationCounter = Int.zero

    var id: String
    var cgWindowId: CGWindowID?
    var lastFocusOrder = Int.zero
    var creationOrder = Int.zero
    var title: String!
    var thumbnail: CALayerContents?
    var icon: CGImage? { get { application.icon } }
    var shouldShowTheUser = true
    var isTabbed: Bool = false
    var tabbedSiblingWids: [CGWindowID]?
    var isHidden: Bool { get { application.isHidden } }
    var dockLabel: String? { get { application.dockLabel } }
    var isFullscreen = false
    var isMinimized = false
    var isOnAllSpaces = false
    var isWindowlessApp: Bool { get { cgWindowId == nil } }
    var isParallelsCoherenceWindow: Bool { application.isParallelsCoherence }
    var position: CGPoint?
    var size: CGSize?
    var spaceIds = [CGSSpaceID.max]
    var spaceIndexes = [SpaceIndex.max]
    var screenId: ScreenUuid?
    var axUiElement: AXUIElement?
    var application: Application
    var axObserver: AXObserver?
    var rowIndex: Int?
    var debugId: String!
    var lastSearchQuery: String?
    var swAppResults: [SWResult] = []
    var swTitleResults: [SWResult] = []
    var swBestSimilarity = 0.0

    init(_ axUiElement: AXUIElement, _ application: Application, _ wid: CGWindowID, _ title: String?, _ isFullscreen: Bool?, _ isMinimized: Bool?, _ position: CGPoint?, _ size: CGSize?) {
        id = "wid-\(wid)"
        self.axUiElement = axUiElement
        self.application = application
        cgWindowId = wid
        self.updateSpacesAndScreen()
        updateFromAxAttributes(title, size, position, isFullscreen, isMinimized)
        debugId = "\(self.application.debugId) (wid:\(cgWindowId) title:\(self.title))"
        Window.globalCreationCounter += 1
        creationOrder = Window.globalCreationCounter
        application.removeWindowlessAppWindow()
        // the app may have timed out trying to subscribe to app notifications
        // It may be responsive now since it has a window; we attempt again
        application.observeEventsIfEligible()
        // fetch app icon only if we display that app in the switcher
        application.fetchAppIcon()
        checkIfFocused()
        Logger.info { self.debugId }
        observeEvents()
    }

    init(_ application: Application) {
        id = "pid-\(application.pid)"
        self.application = application
        title = bestEffortTitle(nil)
        Window.globalCreationCounter += 1
        creationOrder = Window.globalCreationCounter
        debugId = "\(application.debugId) (title:\(title))"
        // fetch app icon only if we display that app in the switcher
        application.fetchAppIcon()
        Logger.debug { self.debugId }
    }

    deinit {
        Logger.info { self.debugId }
    }

    func updateFromAxAttributes(_ title: String?, _ size: CGSize?, _ position: CGPoint?, _ isFullscreen: Bool?, _ isMinimized: Bool?) {
        self.title = bestEffortTitle(title)
        self.size = size
        self.position = position
        self.isFullscreen = isFullscreen ?? false
        self.isMinimized = isMinimized ?? false
        lastSearchQuery = nil
    }

    func isEqualRobust(_ otherWindowAxUiElement: AXUIElement, _ otherWindowWid: CGWindowID?) -> Bool {
        // the window can be deallocated by the OS, in which case its `CGWindowID` will be `-1`
        // we check for equality both on the AXUIElement, and the CGWindowID, in order to catch all scenarios
        return otherWindowAxUiElement == axUiElement || (cgWindowId != nil && cgWindowId != CGWindowID(bitPattern: -1) && otherWindowWid == cgWindowId)
    }

    private func observeEvents() {
        AXObserverCreate(application.pid, AccessibilityEvents.axObserverCallback, &axObserver)
        guard let axObserver else { return }
        AXCallScheduler.shared.schedule(key: "sub-win-\(cgWindowId)", context: debugId, pid: application.pid) { [weak self] in
            guard let self else { return }
            if try self.axUiElement!.subscribeToNotification(axObserver, Window.notifications.first!) {
                Logger.debug { "Subscribed to window: \(self.debugId)" }
                for notification in Window.notifications.dropFirst() {
                    AXCallScheduler.shared.schedule(key: "sub-win-\(cgWindowId)-\(notification)", context: self.debugId, pid: self.application.pid) { [weak self] in
                        try self?.axUiElement!.subscribeToNotification(axObserver, notification)
                    }
                }
            }
        }
        CFRunLoopAddSource(BackgroundWork.accessibilityEventsThread.runLoop, AXObserverGetRunLoopSource(axObserver), .commonModes)
    }

    func refreshThumbnail(_ screenshot: CALayerContents) {
        thumbnail = screenshot
        if !App.appIsBeingUsed || !shouldShowTheUser { return }
        if let position, let size,
           let view = (TilesView.recycledViews.first { $0.window_?.cgWindowId == cgWindowId }) {
            if !view.thumbnail.isHidden {
                let thumbnailSize = TileView.thumbnailSize(size, false)
                let newSize = thumbnailSize.width != view.thumbnail.frame.width || thumbnailSize.height != view.thumbnail.frame.height
                view.thumbnail.updateContents(screenshot, thumbnailSize)
                // if the thumbnail size has changed, we need to refresh the open UI
                if newSize {
                    App.refreshOpenUiAfterExternalEvent([])
                }
            }
            PreviewPanel.updateIfShowing(cgWindowId, screenshot, position, size)
        }
    }

    func canBeClosed() -> Bool {
        return !isWindowlessApp
    }

    func close() {
        if !canBeClosed() {
            NSSound.beep()
            return
        }
        if let altTabWindow = altTabWindow() {
            altTabWindow.close()
            return
        }
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            guard let self else { return }
            if self.isFullscreen {
                try? self.axUiElement!.setAttribute(kAXFullscreenAttribute, false)
                // minimizing is ignored if sent immediatly; we wait for the de-fullscreen animation to be over
                BackgroundWork.accessibilityCommandsQueue.addOperationAfter(deadline: .now() + .seconds(1)) { [weak self] in
                    guard let self else { return }
                    if let closeButton_ = try? self.axUiElement!.attributes([kAXCloseButtonAttribute]).closeButton {
                        try? closeButton_.performAction(kAXPressAction)
                    }
                }
            } else {
                if let closeButton_ = try? self.axUiElement!.attributes([kAXCloseButtonAttribute]).closeButton  {
                    try? closeButton_.performAction(kAXPressAction)
                }
            }
        }
    }

    func canBeMinDeminOrFullscreened() -> Bool {
        return !isWindowlessApp && !isTabbed
    }

    func minDemin() {
        if !canBeMinDeminOrFullscreened() {
            NSSound.beep()
            return
        }
        if let altTabWindow = altTabWindow() {
            isMinimized ? altTabWindow.deminiaturize(nil) : altTabWindow.miniaturize(nil)
            return
        }
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            guard let self else { return }
            if self.isFullscreen {
                try? self.axUiElement!.setAttribute(kAXFullscreenAttribute, false)
                // minimizing is ignored if sent immediatly; we wait for the de-fullscreen animation to be over
                BackgroundWork.accessibilityCommandsQueue.addOperationAfter(deadline: .now() + .seconds(1)) { [weak self] in
                    guard let self else { return }
                    try? self.axUiElement!.setAttribute(kAXMinimizedAttribute, true)
                }
            } else {
                try? self.axUiElement!.setAttribute(kAXMinimizedAttribute, !self.isMinimized)
            }
        }
    }

    func toggleFullscreen() {
        if !canBeMinDeminOrFullscreened() {
            NSSound.beep()
            return
        }
        if let altTabWindow = altTabWindow() {
            altTabWindow.toggleFullScreen(nil)
            return
        }
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            guard let self else { return }
            try? self.axUiElement!.setAttribute(kAXFullscreenAttribute, !self.isFullscreen)
        }
    }

    func focus() {
        // Clear any stale focus guard from a prior Parallels transition.
        // Parallels-involved paths below re-arm for their own target;
        // standard macOS→macOS SLPS path correctly runs with no guard.
        Windows.clearAltTabFocusGuard()
        if let altTabWindow = altTabWindow() {
            App.shared.activate(ignoringOtherApps: true)
            altTabWindow.makeKeyAndOrderFront(nil)
            Windows.previewSelectedWindowIfNeeded()
        } else if isWindowlessApp || cgWindowId == nil || Preferences.onlyShowApplications() {
            if let bundleUrl = application.bundleURL, isWindowlessApp {
                if (try? NSWorkspace.shared.launchApplication(at: bundleUrl, configuration: [:])) == nil {
                    application.runningApplication.activate(options: .activateAllWindows)
                }
            } else {
                application.runningApplication.activate(options: .activateAllWindows)
            }
            Windows.previewSelectedWindowIfNeeded()
        } else if isParallelsCoherenceWindow {
            focusParallelsCoherenceWindow()
        } else if isOutboundFromParallelsCoherence() {
            focusMacOsWindowOverParallelsCoherence()
        } else {
            // macOS bug: when switching to a System Preferences window in another space, it switches to that space,
            // but quickly switches back to another window in that space
            // You can reproduce this buggy behaviour by clicking on the dock icon, proving it's an OS bug
            BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
                guard let self else { return }
                var psn = ProcessSerialNumber()
                GetProcessForPID(self.application.pid, &psn)
                _SLPSSetFrontProcessWithOptions(&psn, self.cgWindowId!, SLPSMode.userGenerated.rawValue)
                self.makeKeyWindow(&psn)
                try? self.axUiElement!.focusWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                    Windows.previewSelectedWindowIfNeeded()
                }
            }
        }
    }

    /// True when a Parallels Coherence app was the foreground app when the
    /// user pressed Alt-Tab and we're focusing a non-Parallels target.
    /// Consults `App.sessionSourcePid` (captured at the very start of the
    /// AltTab session) rather than the live `Applications.frontmostPid`,
    /// because showing the `TilesPanel` can flip the live frontmost to
    /// AltTab's own pid and hide the real source from this check.
    private func isOutboundFromParallelsCoherence() -> Bool {
        guard !application.isParallelsCoherence else { return false }
        let sourcePid = App.sessionSourcePid ?? Applications.frontmostPid
        guard let sourcePid, sourcePid != application.pid,
              let sourceApp = (Applications.list.first { $0.pid == sourcePid }) else { return false }
        return sourceApp.isParallelsCoherence
    }

    /// Parallels Coherence → macOS window path.
    ///
    /// Three problems to solve at once:
    ///   1. `makeKeyWindow` (the Hammerspoon SLPS event-injection trick) and
    ///      `_SLPSSetFrontProcessWithOptions` interact badly with Parallels'
    ///      event mirror — the Coherence window re-raises.
    ///   2. `NSRunningApplication.activate(options: .activateAllWindows)`
    ///      breaks multi-window apps like Terminal.
    ///   3. Even with `activate(options: [])`, Parallels' re-raise can fire
    ///      a few ms after activation and defeat our raise if we fire it
    ///      the instant frontmost flips.
    ///
    /// Strategy: pin the target window's server-level to
    /// `kCGFloatingWindowLevel` for the duration of the transition. While
    /// pinned, the window server enforces z-order at the compositor level,
    /// so Parallels cannot draw its Coherence window on top no matter how
    /// many raises or activations it fires. After 1 second we restore the
    /// target's original level unconditionally so it can't get stuck
    /// elevated. In parallel: activate the target, poll until the frontmost
    /// app becomes the target, then wait an extra settling delay (so
    /// Parallels' one-shot reaction runs and completes first), then fire
    /// `kAXRaiseAction` on the specific target window. The AX raise
    /// handles the "correct window within the app" selection; the level
    /// pin handles the visual stack.
    /// Coherence → macOS. Pin the target high + set front process with the
    /// SPECIFIC target window atomically. Using `_SLPSSetFrontProcessWithOptions`
    /// (not `NSRunningApplication.activate`) because the latter doesn't take
    /// a window argument — it raises whichever window of the target app was
    /// most recently key, which corrupts AltTab's last-focus-order: e.g.
    /// Par→Term1 via AltTab would briefly raise Term2 (previously key in
    /// Terminal) before the AX raise pulled Term1 forward, so the next
    /// AltTab would go to Term2 instead of back to Par. SLPS-with-wid skips
    /// that intermediate raise.
    ///
    /// `makeKeyWindow` (the Hammerspoon byte-blob fake-event trick) is
    /// intentionally omitted — Parallels' event mirror reads the synthetic
    /// events as a click back on the source Coherence window and immediately
    /// re-raises. SLPS-with-wid alone is enough when the target is a
    /// well-behaved macOS app.
    private func focusMacOsWindowOverParallelsCoherence() {
        guard let targetWid = cgWindowId else { return }
        // Arm guard BEFORE SLPS fires so any AX focus-changed event the
        // activation triggers is suppressed (for non-target windows) from
        // the very first event. If the guard were armed after SLPS, a
        // spurious event could race onto the main queue ahead of us.
        Windows.armAltTabFocusGuard(for: self)
        let sourceWid = previouslyFrontmostWindowId()
        CGSDisableUpdate(CGS_CONNECTION)
        pinTargetLevelTemporarily(sourceWid: sourceWid)
        var psn = ProcessSerialNumber()
        GetProcessForPID(application.pid, &psn)
        _SLPSSetFrontProcessWithOptions(&psn, targetWid, SLPSMode.userGenerated.rawValue)
        CGSReenableUpdate(CGS_CONNECTION)
        manuallyUpdateFocusOrderForParallelsTransition()
        pollForTargetAppFrontmostAndRaise(attempt: 0)
    }

    /// Atomically pin the target to kCGScreenSaverWindowLevel AND set it as
    /// the front process + key window via `_SLPSSetFrontProcessWithOptions`
    /// (which takes a specific CGWindowID). Used for macOS → Coherence and
    /// Coherence → Coherence. Prefer SLPS-with-wid over
    /// `NSRunningApplication.activate` because activate() triggers the full
    /// Cocoa/Parallels activation pipeline (including the Parallels event
    /// mirror redrawing both source and target Coherence windows with new
    /// focus states), which visibly flickers on Par→Par switches. SLPS is
    /// a single window-server call with no app-level side effects beyond
    /// "process is front with this window". Compositor is paused around
    /// both the level pin and the SLPS call so they land in one frame.
    private func atomicallyPinAndActivate() {
        guard let targetWid = cgWindowId else { return }
        // Arm guard BEFORE SLPS so any Cocoa-activation AX focus event
        // arrives on main with the suppression filter already in place.
        Windows.armAltTabFocusGuard(for: self)
        let sourceWid = previouslyFrontmostWindowId()
        CGSDisableUpdate(CGS_CONNECTION)
        pinTargetLevelTemporarily(sourceWid: sourceWid)
        var psn = ProcessSerialNumber()
        GetProcessForPID(application.pid, &psn)
        _SLPSSetFrontProcessWithOptions(&psn, targetWid, SLPSMode.userGenerated.rawValue)
        CGSReenableUpdate(CGS_CONNECTION)
        manuallyUpdateFocusOrderForParallelsTransition()
    }

    /// SLPS-with-wid is a direct window-server call that doesn't reliably
    /// trigger `kAXFocusedWindowChangedNotification`. Meanwhile Cocoa
    /// activation of a multi-window target app (e.g. Terminal) often
    /// fires a brief spurious focus-changed for whatever window was
    /// previously key in that app, BEFORE the real target arrives.
    ///
    /// Previously the fix was just an arm-guard + immediate
    /// updateLastFocusOrder(target). But if a spurious event DID slip
    /// through before the guard was armed (or after it expired), that
    /// event would bump some wrong window into position 1. Our
    /// subsequent updateLastFocusOrder(target) moves target to 0, but
    /// the wrong window STAYS at 1 — so the next AltTab offers it
    /// instead of the correct previously-focused window.
    ///
    /// Robust fix: snapshot the full lastFocusOrder state of every
    /// window BEFORE the transition (so we have the true pre-transition
    /// order), arm the guard, immediately promote target, and then at
    /// +500ms and +1000ms atomically RESTORE the snapshot + re-apply the
    /// single promotion. Any spurious updates to other windows in
    /// between are overwritten. Skipped if the user has AltTab'd again
    /// in the meantime (generation counter check).
    private func manuallyUpdateFocusOrderForParallelsTransition() {
        let snapshot = Windows.list.map { (window: $0, order: $0.lastFocusOrder) }
        Windows.parallelsTransitionGeneration &+= 1
        let myGeneration = Windows.parallelsTransitionGeneration
        Windows.armAltTabFocusGuard(for: self)
        application.focusedWindow = self
        _ = Windows.updateLastFocusOrder(self)
        for delayMs in [500, 1000] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard let self, Windows.parallelsTransitionGeneration == myGeneration else { return }
                for (window, order) in snapshot { window.lastFocusOrder = order }
                _ = Windows.updateLastFocusOrder(self)
            }
        }
    }

    /// The CGWindowID of the source app's focused window at the moment the
    /// AltTab session started — used so we can explicitly order the target
    /// above it when the level pin restores, avoiding a z-order flip.
    private func previouslyFrontmostWindowId() -> CGWindowID? {
        guard let sourcePid = App.sessionSourcePid ?? Applications.frontmostPid,
              sourcePid != application.pid,
              let sourceApp = (Applications.list.first { $0.pid == sourcePid }) else { return nil }
        return sourceApp.focusedWindow?.cgWindowId
    }

    private static let parallelsOutboundPollAttempts = 20 // 20 × 5ms = 100ms budget
    private static let parallelsOutboundPollIntervalMs = 5
    /// Settle-after-flip delay: was 140ms when Parallels was actively
    /// fighting via the Windows Start menu path. With Cmd→Ctrl remapping
    /// in Parallels, the Start menu no longer opens on Cmd, so Parallels
    /// has far less to react to. 40ms is enough buffer for any remaining
    /// async reaction while keeping the transition snappy.
    private static let parallelsOutboundSettleMs = 40
    private func pollForTargetAppFrontmostAndRaise(attempt: Int) {
        let targetPid = application.pid
        let targetIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid
        if targetIsFrontmost || attempt >= Window.parallelsOutboundPollAttempts {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(Window.parallelsOutboundSettleMs)
            ) { [weak self] in
                guard let self else { return }
                BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
                    guard let self else { return }
                    try? self.axUiElement!.focusWindow()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                    Windows.previewSelectedWindowIfNeeded()
                }
            }
            return
        }
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Window.parallelsOutboundPollIntervalMs)
        ) { [weak self] in
            self?.pollForTargetAppFrontmostAndRaise(attempt: attempt + 1)
        }
    }

    /// Pin the target window to kCGScreenSaverWindowLevel (1000) so it
    /// draws above everything while Parallels' Coherence integration
    /// settles. Restore after 3s — deliberately long so the restore
    /// happens well after any user-perceived transition, not during it.
    /// The restore is atomic (order target above source + drop level,
    /// under CGSDisableUpdate) so if Parallels raised its source
    /// Coherence window to the top of level-0 during the pin, the drop
    /// doesn't show a z-order flip.
    ///
    /// Downside of a longer pin: if the user alt-tabs again within 3s,
    /// the previously-pinned window would stay on top above the new
    /// target. Mitigation is that the next focus() call pins the NEW
    /// target higher (same level, but ordered above), so the user-visible
    /// "currently selected" window stays correct.
    private func pinTargetLevelTemporarily(sourceWid: CGWindowID?) {
        guard let targetWid = cgWindowId else { return }
        var originalLevel: CGWindowLevel = 0
        CGSGetWindowLevel(CGS_CONNECTION, targetWid, &originalLevel)
        let kCGScreenSaverWindowLevel: CGWindowLevel = 1000
        CGSSetWindowLevel(CGS_CONNECTION, targetWid, kCGScreenSaverWindowLevel)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(3000)) {
            CGSDisableUpdate(CGS_CONNECTION)
            if let sourceWid {
                CGSOrderWindow(CGS_CONNECTION, targetWid, CGSWindowOrderingMode.above.rawValue, sourceWid)
            }
            CGSSetWindowLevel(CGS_CONNECTION, targetWid, originalLevel)
            CGSReenableUpdate(CGS_CONNECTION)
        }
    }

    /// Focus path for Parallels Coherence windows (macOS → Coherence or
    /// Coherence → Coherence). Avoids the SLPS path (`makeKeyWindow`
    /// synthetic events) which can cause flicker even when Parallels is the
    /// target. Wrap the pin+activate in a window-server compositing pause
    /// so the two changes land as one atomic frame, eliminating the
    /// intermediate-frame flicker visible when they happen in sequence.
    private func focusParallelsCoherenceWindow() {
        atomicallyPinAndActivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            guard let self else { return }
            BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
                guard let self else { return }
                try? self.axUiElement!.focusWindow()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                Windows.previewSelectedWindowIfNeeded()
            }
        }
    }

    /// The following function was ported from https://github.com/Hammerspoon/hammerspoon/issues/370#issuecomment-545545468
    private func makeKeyWindow(_ psn: inout ProcessSerialNumber) -> Void {
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        memcpy(&bytes[0x3c], &cgWindowId, MemoryLayout<UInt32>.size)
        memset(&bytes[0x20], 0xff, 0x10)
        bytes[0x08] = 0x01
        SLPSPostEventRecordTo(&psn, &bytes)
        bytes[0x08] = 0x02
        SLPSPostEventRecordTo(&psn, &bytes)
    }

    // for some windows (e.g. Slack), the AX API doesn't return a title; we try CG API; finally we resort to the app name
    func bestEffortTitle(_ axTitle: String?) -> String {
        if let axTitle, !axTitle.isEmpty {
            return axTitle
        }
        if let cgWindowId, let cgTitle = cgWindowId.title(), !cgTitle.isEmpty {
            return cgTitle
        }
        return application.localizedName ?? ""
    }

    func updateSpacesAndScreen() {
        // macOS bug: if you tab a window, then move the tab group to another space, other tabs from the tab group will stay on the current space
        // you can use the Dock to focus one of the other tabs and it will teleport that tab in the current space, proving that it's a macOS bug
        // note: for some reason, it behaves differently if you minimize the tab group after moving it to another space
        updateSpaces()
        updateScreenId()
    }

    private func updateSpaces() {
        guard let cgWindowId else { return }
        var spaceIds = cgWindowId.spaces()
        // inactive tabs return no space from CGSCopySpacesForWindows; use the active tab sibling's space
        if spaceIds.isEmpty, let activeTab = TabGroup.activeTabSibling(of: self) {
            spaceIds = activeTab.spaceIds
        }
        self.spaceIds = spaceIds
        self.spaceIndexes = spaceIds.compactMap { spaceId in Spaces.idsAndIndexes.first { $0.0 == spaceId }?.1 }
        self.isOnAllSpaces = spaceIds.count > 1
    }

    private func updateScreenId() {
        screenId = NSScreen.screens.first { isOnScreen($0) }?.cachedUuid()
    }

    /// window may not be visible on that screen (e.g. the window is not on the current Space)
    func isOnScreen(_ screen: NSScreen) -> Bool {
        if NSScreen.screensHaveSeparateSpaces {
            if let screenUuid = screen.cachedUuid(), let screenSpaces = Spaces.screenSpacesMap[screenUuid] {
                return screenSpaces.contains { screenSpace in spaceIds.contains { $0 == screenSpace } }
            }
        } else {
            let referenceWindow = referenceWindowForTabbedWindow()
            if let topLeftCorner = referenceWindow?.position, let size = referenceWindow?.size {
                var screenFrameInQuartzCoordinates = screen.frame
                screenFrameInQuartzCoordinates.origin.y = NSMaxY(NSScreen.screens[0].frame) - NSMaxY(screen.frame)
                let windowRect = CGRect(origin: topLeftCorner, size: size)
                return windowRect.intersects(screenFrameInQuartzCoordinates)
            }
        }
        return true
    }

    func referenceWindowForTabbedWindow() -> Window? {
        // if the window is tabbed, we can't know its position/size before it's focused, so we use the currently
        // visible window-tab. Its data will match the tabbed window's
        // fallback to the focusedWindow
        isTabbed ? (TabGroup.activeTabSibling(of: self) ?? application.focusedWindow) : self
    }

    // Determines if this window is the main application window
    func isAppMainWindow() -> Bool {
        // AX calls done on main thread. They can block thus freeze the UI
        // TODO: find a better approach
        guard let appAxUiElement = application.axUiElement,
              let mainWindow = try? appAxUiElement.attributes([kAXMainWindowAttribute]).mainWindow else { return false }
        return (try? mainWindow.cgWindowId()) == cgWindowId
    }

    private func altTabWindow() -> NSWindow? {
        if application.bundleURL == App.bundleURL, let cgWindowId {
            return App.shared.window(withWindowNumber: Int(cgWindowId))
        }
        return nil
    }

    /// Scenarios addressed by this:
    /// * Some apps will not trigger AXApplicationActivated, where we usually update application.focusedWindow
    /// * Sometimes, we subscribe to an app after it has emitted the focusedWindow / applicationActivated events, so we never receive these
    private func checkIfFocused() {
        let app = application
        guard let appAxUiElement = app.axUiElement else { return }
        AXCallScheduler.shared.schedule(key: "wid-\(cgWindowId)-focus", context: debugId, pid: app.pid) { [weak app] in
            guard let app, let focusedWindow = try appAxUiElement.attributes([kAXFocusedWindowAttribute]).focusedWindow else { return }
            let focusedWid = try focusedWindow.cgWindowId()
            DispatchQueue.main.async {
                guard let window = (Windows.list.first { $0.isEqualRobust(focusedWindow, focusedWid) }) else { return }
                app.focusedWindow = window
                if let windows = Windows.updateLastFocusOrder(window) {
                    App.refreshOpenUiAfterExternalEvent(windows)
                }
            }
        }
    }
}
