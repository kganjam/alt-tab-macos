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
        let newTitle = bestEffortTitle(title)
        self.title = newTitle
        self.size = size
        self.position = position
        self.isFullscreen = isFullscreen ?? false
        self.isMinimized = isMinimized ?? false
        lastSearchQuery = nil
        // Keep debugId in sync with title. Tile labels and focus logs derive
        // from debugId; RECENCY/MOUSE logs read self.title. Without this the
        // two drift on Parallels Coherence pages and AltTab shows stale page
        // names that no longer match the live window.
        if let wid = cgWindowId {
            debugId = "\(application.debugId) (wid:\(wid) title:\(newTitle))"
        } else {
            debugId = "\(application.debugId) (title:\(newTitle))"
        }
    }

    /// Parallels Coherence rewrites the window title on guest page/tab
    /// navigation but does not reliably fire kAXTitleChangedNotification,
    /// nor does the per-window CGSCopyWindowProperty("kCGSWindowTitle")
    /// reflect the live value. Only `kCGWindowName` from
    /// CGWindowListCopyWindowInfo returns the current guest-side title.
    /// Caller supplies the fresh title; we update if it differs.
    func refreshTitleIfChanged(_ liveTitle: String?) {
        guard let wid = cgWindowId, let liveTitle, !liveTitle.isEmpty,
              liveTitle != title else { return }
        Diagnostics.log("TITLE", "wid=\(wid) '\(title ?? "")' → '\(liveTitle)'")
        title = liveTitle
        lastSearchQuery = nil
        debugId = "\(application.debugId) (wid:\(wid) title:\(liveTitle))"
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
        Diagnostics.markSwitchPhase("Window.focus")
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
        } else if isParallelsCoherenceWindow && isSameProcessAsCurrentFrontmost() {
            focusParallelsCoherenceWindowSameProcess()
        } else if isParallelsCoherenceWindow {
            focusParallelsCoherenceWindow()
        } else if isOutboundFromParallelsCoherence() {
            focusMacOsWindowOverParallelsCoherence()
        } else {
            // SLPS + makeKeyWindow are fast WindowServer IPCs (~sub-ms);
            // run them inline for minimum switch latency. Only the AX
            // call (an RPC into the target process, can block 10-100ms)
            // is dispatched to the accessibilityCommandsQueue.
            //
            // macOS bug context (still relevant): when switching to a
            // System Preferences window in another space, it switches
            // to that space, but quickly switches back to another window
            // in that space. Reproducible via Dock-icon click → it's an
            // OS bug, not threading-related.
            var psn = ProcessSerialNumber()
            GetProcessForPID(application.pid, &psn)
            _SLPSSetFrontProcessWithOptions(&psn, cgWindowId!, SLPSMode.userGenerated.rawValue)
            Diagnostics.markSwitchPhase("slpsDone")
            makeKeyWindow(&psn)
            Diagnostics.markSwitchPhase("makeKeyDone")
            BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
                guard let self else { return }
                Diagnostics.markSwitchPhase("axQueueEntry")
                try? self.axUiElement!.focusWindow()
                Diagnostics.markSwitchPhase("axDone", extra: "wid=\(self.cgWindowId ?? 0)")
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
        Diagnostics.log("FOCUS", "enter focusMacOsWindowOverParallelsCoherence target=\(debugId ?? "?")")
        guard let targetWid = cgWindowId else { return }
        Windows.armAltTabFocusGuard(for: self)
        var psn = ProcessSerialNumber()
        GetProcessForPID(application.pid, &psn)
        _SLPSSetFrontProcessWithOptions(&psn, targetWid, SLPSMode.userGenerated.rawValue)
        makeKeyWindow(&psn)
        Diagnostics.log("API", "Par→mac: SLPS+makeKey(wid=\(targetWid))")
        // AX `focusWindow()` is synchronous AX RPC with a 1s timeout; if the
        // target app is inactive (Safari WebApps especially), this blocks the
        // main thread for hundreds of ms — the panel freezes, queued
        // keystrokes fire late, and Parallels' coherence reconciliation can
        // win the z-order race during the freeze. SLPS-with-wid already
        // raised the target; this AX raise is supplementary, so safe to
        // run off-thread.
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            try? self?.axUiElement?.focusWindow()
            Diagnostics.log("API", "Par→mac: AX raise(wid=\(targetWid)) done")
        }
        manuallyUpdateFocusOrderForParallelsTransition()
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
    /// Target-is-Parallels path (mac→Par, Par→Par). Uses the full
    /// stock SLPS flow (SLPS + makeKeyWindow + AX raise) because the
    /// target is a Parallels Coherence window that needs the "synthetic
    /// click" events to route keyboard into its Windows guest. The
    /// concern that makeKeyWindow confuses Parallels applies only when
    /// the SOURCE is a Coherence window (Par→mac) — for Par targets,
    /// Parallels PROPERLY interprets the synthetic events as user
    /// activation of that specific Coherence window. Without
    /// makeKeyWindow, keyboard continues to go to the previous app
    /// (e.g. Terminal).
    private func atomicallyPinAndActivate() {
        Diagnostics.log("FOCUS", "enter atomicallyPinAndActivate target=\(debugId ?? "?")")
        guard let targetWid = cgWindowId else { return }
        Windows.armAltTabFocusGuard(for: self)
        var psn = ProcessSerialNumber()
        GetProcessForPID(application.pid, &psn)
        // noWindows mode: activates process without raising ANY windows.
        // makeKeyWindow: routes keyboard into Windows guest.
        // AX raise: brings only the target window to z0.
        // ZENFORCE handles any subsequent Parallels z-order steals.
        _SLPSSetFrontProcessWithOptions(&psn, targetWid, SLPSMode.noWindows.rawValue)
        makeKeyWindow(&psn)
        Diagnostics.log("API", "mac→Par: SLPS(noWin)+makeKey(wid=\(targetWid))")
        // kAXFrontmost setter: explicit AX-side "this app is frontmost"
        // signal. Distinct from kAXFocusedWindowAttribute (which sets the
        // window WITHIN the app). Empirically, when the source app holds
        // a stale AX-frontmost claim, kAXFocusedWindow and SLPS alone
        // aren't enough to fully transfer input routing — characters
        // typed during the gap leak into the source. This setter closes
        // that specific divergence.
        if let appAx = application.axUiElement {
            let err = AXUIElementSetAttributeValue(appAx, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            Diagnostics.log("FRONTMOSTSET", "atomicallyPinAndActivate kAXFrontmost=true pid=\(application.pid) wid=\(targetWid) → \(err == .success ? "OK" : "err=\(err.rawValue)")")
        }
        // Phase 3 IPC: tell the Windows guest to SetForegroundWindow on
        // the corresponding Win32 hwnd. This is the most authoritative
        // foreground-transfer mechanism we have — it goes through the
        // actual Windows OS focus pipeline rather than the macOS
        // compositor's host↔guest sync. Async on Winside.queue; safe
        // no-op if helper isn't running. Title-based lookup; helper
        // caches LIST results, so steady-state cost is one TCP round
        // trip (~30ms via nc).
        if let title = self.title {
            Winside.setForegroundForTitleAsync(title, label: "atomicallyPinAndActivate wid=\(targetWid)")
        }
        // Same rationale as `focusMacOsWindowOverParallelsCoherence`: keep
        // the slow AX RPC off the main thread.
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            try? self?.axUiElement?.focusWindow()
            Diagnostics.log("API", "mac→Par: AX raise(wid=\(targetWid)) done")
        }
        manuallyUpdateFocusOrderForParallelsTransition()
    }

    /// SLPS-with-wid is a direct window-server call that doesn't reliably
    /// trigger `kAXFocusedWindowChangedNotification`. Arm the guard and
    /// promote target synchronously. Explicitly set BOTH target to
    /// position 0 AND the session-start source window to position 1 —
    /// this is more robust than `updateLastFocusOrder(target)` alone,
    /// which can leave a previously-corrupted window at position 1.
    /// The source is looked up from `App.sessionSourcePid` (captured
    /// before the TilesPanel showed, so it reflects the real pre-
    /// session foreground app, not AltTab itself).
    ///
    /// Also updates `Applications.frontmostPid` to the target's pid so
    /// the next AltTab session reads a fresh value — `NSWorkspace` and
    /// AX notifications can lag behind our SLPS-initiated change by
    /// many ms, and a stale value causes session-start normalize to
    /// use the wrong "current" pid.
    private func manuallyUpdateFocusOrderForParallelsTransition() {
        Windows.armAltTabFocusGuard(for: self)
        application.focusedWindow = self
        Applications.frontmostPid = application.pid
        App.lastFocusedTargetWid = cgWindowId
        App.lastFocusedTargetPid = application.pid
        App.lastFocusedTargetTime = CFAbsoluteTimeGetCurrent()
        let source = sessionSourceWindow()
        Diagnostics.log("MANUAL", "manualUpdate target=\(debugId ?? "?") source=\(source?.debugId ?? "nil")")
        Windows.setTargetAndSourceAsMostRecent(target: self, source: source)
        Diagnostics.logTrackedRecency("after manualUpdate")
        // Two delayed captures:
        //   +400ms — right after any one-shot Parallels re-raise settles
        //   +2500ms — catches delayed re-raise / Parallels polling behavior
        // Both run on a background queue so they don't block main.
        for delayMs in [400, 2500] {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard let self else { return }
                Diagnostics.logSystemZOrder("post-manualUpdate +\(delayMs)ms")
                Diagnostics.logFrontmostSignals("post-manualUpdate +\(delayMs)ms")
                _ = self.cgWindowId
            }
        }
    }

    /// Looks up the Window the user was focused on when this AltTab
    /// session started, via `App.sessionSourceWid`. Returns nil if it
    /// resolves to this same window (so we have no separate "previous"
    /// window to promote) or can't be found.
    private func sessionSourceWindow() -> Window? {
        guard let wid = App.sessionSourceWid, wid != cgWindowId else { return nil }
        return Windows.list.first { $0.cgWindowId == wid }
    }

    /// The CGWindowID of the source app's focused window at the moment the
    /// AltTab session started — used so we can explicitly order the target
    /// above it when the level pin restores, avoiding a z-order flip.
    /// Parallels has a timer that re-activates its Coherence window
    /// ~800-1500ms after any focus transition. Our initial SLPS +
    /// makeKeyWindow + AX raise at t=0 succeeds immediately but gets
    /// overridden when Parallels' timer fires. CGSSetWindowLevel and
    /// CGSOrderWindow are both no-ops for cross-process windows (the
    /// level-pin was a database-only change, not compositor-enforced).
    ///
    /// After SLPS + makeKeyWindow, Parallels has window-level focus but
    /// the Windows-side element-level focus may be wrong (e.g., toolbar
    /// vs content area). Send a benign Shift press/release to trigger
    /// True if the target window's app is already the frontmost process.
    /// Used to take a lighter-weight focus path for Par→Par (same OneNote
    /// process). When the app is already front, we don't need SLPS/
    /// makeKeyWindow/activate — just AX to change the key window.
    private func isSameProcessAsCurrentFrontmost() -> Bool {
        // Live `frontmostPid` is the truth: updated by AX activation events
        // and by `manuallyUpdateFocusOrderForParallelsTransition`. Use
        // `sessionSourcePid` ONLY when frontmostPid is unusable (nil or
        // AltTab itself during panel display). Session source is a frozen
        // snapshot from session start, so it becomes stale if the user
        // alt-tabs through multiple windows within one panel session.
        let altTabPid = ProcessInfo.processInfo.processIdentifier
        if let fp = Applications.frontmostPid, fp != altTabPid {
            return application.pid == fp
        }
        return application.pid == App.sessionSourcePid
    }

    /// Par→Par SAME PROCESS. Both source and target are Coherence windows
    /// in the same prl_client_app (e.g. two OneNote notebooks). The app
    /// is already frontmost. Using the full SLPS + makeKeyWindow +
    /// activate bombardment triggers 4+ Parallels render passes (each
    /// signal tells Parallels to re-draw focus state). Instead, just use
    /// AX: set the app's focused window attribute to the target and raise
    /// it. This is one signal → one Parallels render → minimal flicker.
    private func focusParallelsCoherenceWindowSameProcess() {
        Diagnostics.log("FOCUS", "enter focusParallelsCoherenceWindowSameProcess target=\(debugId ?? "?")")
        manuallyUpdateFocusOrderForParallelsTransition()
        let targetWid = cgWindowId
        // kAXFrontmost setter: same rationale as in atomicallyPinAndActivate.
        // The same-process path doesn't fire SLPS — it goes purely
        // through AX. Without setting kAXFrontmost on the app, the
        // app-level "this window is on top" claim can lag and other
        // siblings of the same Parallels app can briefly assert
        // foreground. Cheap call; runs before the AX-raise.
        if let appAx = application.axUiElement {
            let err = AXUIElementSetAttributeValue(appAx, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            Diagnostics.log("FRONTMOSTSET", "sameProcess kAXFrontmost=true pid=\(application.pid) wid=\(targetWid ?? 0) → \(err == .success ? "OK" : "err=\(err.rawValue)")")
        }
        // Phase 3 IPC: send-key-event-equivalent into the guest. For
        // same-process Parallels switches (e.g. two OneNote pages),
        // the macOS-side AX raise is the only mechanism that
        // historically worked, but Parallels' guest-side z-order
        // doesn't always sync immediately — Winside.SET issues the
        // authoritative SetForegroundWindow inside Windows.
        if let title = self.title {
            Winside.setForegroundForTitleAsync(title, label: "sameProcess wid=\(targetWid ?? 0)")
        }
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            guard let self, let appAx = self.application.axUiElement,
                  let selfAx = self.axUiElement else { return }
            try? appAx.setAttribute(kAXFocusedWindowAttribute, selfAx)
            Diagnostics.log("API", "AX setAttribute(focusedWindow, wid=\(targetWid ?? 0))")
            try? selfAx.focusWindow()
            Diagnostics.log("API", "AX focusWindow(wid=\(targetWid ?? 0)) done")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
            Windows.previewSelectedWindowIfNeeded()
        }
    }

    /// mac→Par CROSS PROCESS. Target is a Parallels Coherence window but
    /// the source is a different app. Need full SLPS + makeKeyWindow to
    /// activate the Parallels process and signal keyboard forwarding.
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
    func makeKeyWindow(_ psn: inout ProcessSerialNumber) -> Void {
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
