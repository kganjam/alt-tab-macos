import Cocoa

@_silgen_name("CGPostMouseEvent")
func CGPostMouseEventNoCursor(_ mouseCursorPosition: CGPoint, _ updateMouseCursorPosition: boolean_t, _ buttonCount: CGButtonCount, _ mouseButtonDown: boolean_t) -> CGError

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
    /// The thumbnail bitmap. Storage lives in `ThumbnailCache.shared` so
    /// background captures can write to it without hopping to main. Reads
    /// here are an O(1) dict lookup + uncontended NSLock (~ns).
    var thumbnail: CALayerContents? {
        guard let wid = cgWindowId else { return nil }
        return ThumbnailCache.shared.read(wid: wid)
    }
    var thumbnailUpdatedAt: CFAbsoluteTime {
        guard let wid = cgWindowId else { return 0 }
        return ThumbnailCache.shared.lastUpdatedAt(wid: wid)
    }
    var thumbnailUpdateCount = 0
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
    private var fastFocusAxElement: AXUIElement?
    private var fastFocusAxElementWid: CGWindowID?
    private var fastFocusAxElementAt: CFAbsoluteTime = 0
    private var fastFocusAxLastAttemptAt: CFAbsoluteTime = 0
    private var fastFocusAxPrewarmInFlight = false
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
        // AXObserverCreate + CFRunLoopAddSource pin the observer to the
        // accessibility events runloop. Without explicit removal, the
        // runloop source keeps a strong reference to the observer (which
        // in turn back-references this Window's axUiElement and the
        // notification callbacks). ARC can't reclaim any of it. Pair the
        // observe with this teardown so closed windows release cleanly.
        if let axObserver {
            CFRunLoopRemoveSource(BackgroundWork.accessibilityEventsThread.runLoop,
                                  AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
    }

    func updateFromAxAttributes(_ title: String?, _ size: CGSize?, _ position: CGPoint?, _ isFullscreen: Bool?, _ isMinimized: Bool?) {
        let newTitle = bestEffortTitle(title)
        let geometryChanged = self.size != nil && size != nil && self.size != size
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
        if geometryChanged {
            invalidateThumbnail()
        }
    }

    func invalidateThumbnail() {
        if let wid = cgWindowId {
            ThumbnailCache.shared.clearThumbnail(wid: wid)
        }
        guard App.appIsBeingUsed,
              let view = (TilesView.recycledViews.first { $0.window_?.cgWindowId == cgWindowId }),
              !view.thumbnail.isHidden else { return }
        if let icon {
            view.thumbnail.updateContents(.cgImage(icon), TileView.thumbnailSize(icon.size(), true))
        } else {
            view.thumbnail.releaseImage()
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

    func refreshThumbnail(_ screenshot: CALayerContents, liveSurface: Bool = true) {
        if let wid = cgWindowId {
            ThumbnailCache.shared.writeCapture(wid: wid, image: screenshot, liveSurface: liveSurface)
        }
        thumbnailUpdateCount += 1
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
        prepareForFocus()
        Windows.nextZOrderFocusGeneration()
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
            manuallyUpdateFocusOrderForDirectFocus()
            Windows.previewSelectedWindowIfNeeded()
        } else if isParallelsCoherenceWindow && isSameProcessAsCurrentFrontmost() {
            focusParallelsCoherenceWindowSameProcess()
        } else if isParallelsCoherenceWindow {
            focusParallelsCoherenceWindow()
        } else if isOutboundFromParallelsCoherence() {
            focusMacOsWindowOverParallelsCoherence()
        } else {
            focusNativeMacWindowLikeUpstream()
        }
    }

    func prepareForFocus() {
        deminimizeBeforeFocusIfNeeded()
        refreshWindowIdFromAxIfNeeded()
    }

    private func deminimizeBeforeFocusIfNeeded() {
        guard isMinimized, canBeMinDeminOrFullscreened() else { return }
        if let altTabWindow = altTabWindow() {
            altTabWindow.deminiaturize(nil)
            isMinimized = false
            Diagnostics.log("MINIMIZE", "deminimizeBeforeFocus nativeWindow wid=\(cgWindowId ?? 0)")
            return
        }
        guard let axUiElement else { return }
        AXUIElementSetMessagingTimeout(axUiElement, 0.25)
        let err = AXUIElementSetAttributeValue(axUiElement, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        Diagnostics.log("MINIMIZE", "deminimizeBeforeFocus wid=\(cgWindowId ?? 0) err=\(err.rawValue)")
        if err == .success {
            isMinimized = false
            Windows.requestZOrderReview(reason: "focus-deminiaturized", wid: cgWindowId ?? 0, invalidate: cgWindowId != nil, fullDelayMs: 200)
        }
    }

    private func refreshWindowIdFromAxIfNeeded() {
        guard cgWindowId == nil, let axUiElement, let refreshed = try? axUiElement.cgWindowId(), refreshed != 0 else { return }
        cgWindowId = refreshed
        id = "wid-\(refreshed)"
        debugId = "\(application.debugId) (wid:\(cgWindowId) title:\(title))"
        updateSpacesAndScreen()
        Diagnostics.log("MINIMIZE", "refreshed window id before focus wid=\(refreshed)")
    }

    private func focusNativeMacWindowLikeUpstream() {
        let generation = Windows.currentZOrderFocusGeneration()
        let enqueuedAt = CFAbsoluteTimeGetCurrent()
        guard let targetWid = cgWindowId else { return }
        let preZ = Windows.zOrderSnapshotForFocus()
        if shouldUsePerWindowNativeFocus() {
            var psn = ProcessSerialNumber()
            GetProcessForPID(application.pid, &psn)
            focusNativeMultiWindow(&psn, targetWid, preZ)
            return
        }
        let mode = nativeFocusMode()
        if mode == "hidTitlebarClick" {
            focusNativeMacWindowViaHidTitlebarClick(generation, enqueuedAt)
            return
        }
        if mode == "skyLightEventFocus" {
            focusNativeMacWindowViaSkyLightClick(generation, enqueuedAt, preZ)
            return
        }
        if mode.hasPrefix("noWindows") || mode == "skyLightClickFocus" {
            Diagnostics.log("FOCUS", "ignoring unsafe nativeFocusMode=\(mode); using original per-window focus")
        }
        focusNativeMacWindowOriginalAltTab(generation, enqueuedAt, preZ)
    }

    private func focusNativeMacWindowViaSkyLightClick(_ generation: Int64, _ enqueuedAt: CFAbsoluteTime, _ preZ: [Windows.PreZEntry]) {
        guard Windows.isCurrentZOrderFocusGeneration(generation), let targetWid = cgWindowId else { return }
        let startedAt = CFAbsoluteTimeGetCurrent()
        var psn = ProcessSerialNumber()
        GetProcessForPID(application.pid, &psn)
        let skyLightPosted = postSkyLightFocusClick(targetWid)
        let skyLightAt = CFAbsoluteTimeGetCurrent()
        Diagnostics.markSwitchPhase("skyLightClickDone", extra: "posted=\(skyLightPosted) wid=\(targetWid)")
        guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
        _SLPSSetFrontProcessWithOptions(&psn, targetWid, SLPSMode.userGenerated.rawValue)
        let slpsAt = CFAbsoluteTimeGetCurrent()
        Diagnostics.markSwitchPhase("slpsDone", extra: "skyLightClickFocus")
        guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
        makeKeyWindow(&psn)
        let makeKeyAt = CFAbsoluteTimeGetCurrent()
        Diagnostics.markSwitchPhase("makeKeyDone", extra: "skyLightClickFocus")
        manuallyUpdateFocusOrderForDirectFocus()
        Windows.armNativeFocusZOrderIntent(for: self, preZ: preZ)
        let axEnqueuedAt = CFAbsoluteTimeGetCurrent()
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            guard Windows.isCurrentZOrderFocusGeneration(generation), let self, let targetWid = self.cgWindowId else { return }
            let axStartedAt = CFAbsoluteTimeGetCurrent()
            if let axUiElement = self.axUiElement {
                AXUIElementSetMessagingTimeout(axUiElement, self.nativeMultiWindowAxTimeout())
                try? axUiElement.focusWindow()
            }
            let finishedAt = CFAbsoluteTimeGetCurrent()
            Diagnostics.log("AXFOCUS", String(format: "wid=%u source=skyLightClickFocus queue=%.1fms sky=%.1fms slps=%.1fms makeKey=%.1fms axQueue=%.1fms ax=%.1fms main=%.1fms total=%.1fms endToEnd=%.1fms", targetWid, (startedAt - enqueuedAt) * 1000, (skyLightAt - startedAt) * 1000, (slpsAt - skyLightAt) * 1000, (makeKeyAt - slpsAt) * 1000, (axStartedAt - axEnqueuedAt) * 1000, (finishedAt - axStartedAt) * 1000, (makeKeyAt - startedAt) * 1000, (finishedAt - startedAt) * 1000, (finishedAt - enqueuedAt) * 1000))
            Diagnostics.markSwitchPhase("axDone", extra: "skyLightClickFocus wid=\(targetWid)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
            guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
            Windows.previewSelectedWindowIfNeeded()
            Windows.requestZOrderTopReview(reason: "skylight-click-focus", wid: targetWid)
        }
    }

    private func focusNativeMacWindowViaNoWindowsAxActivate(_ generation: Int64, _ enqueuedAt: CFAbsoluteTime) {
        manuallyUpdateFocusOrderForDirectFocus()
        BackgroundWork.focusActionsQueue.addOperation { [weak self] in
            guard Windows.isCurrentZOrderFocusGeneration(generation), let self, let targetWid = self.cgWindowId else { return }
            let startedAt = CFAbsoluteTimeGetCurrent()
            let queueWaitMs = (startedAt - enqueuedAt) * 1000
            var psn = ProcessSerialNumber()
            GetProcessForPID(self.application.pid, &psn)
            _SLPSSetFrontProcessWithOptions(&psn, targetWid, SLPSMode.noWindows.rawValue)
            let slpsAt = CFAbsoluteTimeGetCurrent()
            Diagnostics.markSwitchPhase("slpsDone", extra: "noWindowsAxActivate")
            let clickFallback = self.nativeClickFallbackEnabled()
            if clickFallback {
                self.scheduleNativeClickFallback(targetWid, generation)
            }
            let axTarget = self.nativeAxTarget(targetWid)
            let resolvedAt = CFAbsoluteTimeGetCurrent()
            let mainErr = self.setNativeAxMainAndFocused(axTarget)
            let mainAt = CFAbsoluteTimeGetCurrent()
            var raiseErr = AXError.failure
            if let axTarget {
                AXUIElementSetMessagingTimeout(axTarget, self.nativeMultiWindowAxTimeout())
                raiseErr = AXUIElementPerformAction(axTarget, kAXRaiseAction as CFString)
            }
            let raiseAt = CFAbsoluteTimeGetCurrent()
            guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
            let activateOk = self.application.runningApplication.activate(options: [])
            let finishedAt = CFAbsoluteTimeGetCurrent()
            Diagnostics.log("AXFOCUS", String(format: "wid=%u source=noWindowsAxActivate queue=%.1fms slps=%.1fms resolve=%.1fms axSet=%.1fms axRaise=%.1fms activate=%.1fms mainErr=%d focusErr=%d raiseErr=%d activateOk=%@ total=%.1fms endToEnd=%.1fms", targetWid, queueWaitMs, (slpsAt - startedAt) * 1000, (resolvedAt - slpsAt) * 1000, (mainAt - resolvedAt) * 1000, (raiseAt - mainAt) * 1000, (finishedAt - raiseAt) * 1000, mainErr.main.rawValue, mainErr.focus.rawValue, raiseErr.rawValue, activateOk ? "true" : "false", (finishedAt - startedAt) * 1000, (finishedAt - enqueuedAt) * 1000))
            if !clickFallback {
                Windows.retryNativeFocusTargetIfNeeded(targetWid: targetWid, targetPid: self.application.pid, delayMs: 120)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
                Windows.previewSelectedWindowIfNeeded()
                Windows.requestZOrderTopReview(reason: "no-windows-ax-activate", wid: targetWid)
            }
        }
    }

    private func focusNativeMacWindowViaHidTitlebarClick(_ generation: Int64, _ enqueuedAt: CFAbsoluteTime) {
        manuallyUpdateFocusOrderForDirectFocus()
        BackgroundWork.focusActionsQueue.addOperation { [weak self] in
            guard Windows.isCurrentZOrderFocusGeneration(generation), let self, let targetWid = self.cgWindowId else { return }
            let startedAt = CFAbsoluteTimeGetCurrent()
            let queueWaitMs = (startedAt - enqueuedAt) * 1000
            let result = self.postNativeTitlebarClick(targetWid)
            let finishedAt = CFAbsoluteTimeGetCurrent()
            Diagnostics.log("AXFOCUS", String(format: "wid=%u source=hidTitlebarClick queue=%.1fms posted=%@ reason=%@ point=%@ total=%.1fms endToEnd=%.1fms", targetWid, queueWaitMs, result.posted ? "true" : "false", result.reason, result.pointText, (finishedAt - startedAt) * 1000, (finishedAt - enqueuedAt) * 1000))
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
                Windows.previewSelectedWindowIfNeeded()
                Windows.requestZOrderTopReview(reason: "hid-titlebar-click", wid: targetWid)
            }
        }
    }

    private func nativeClickFallbackEnabled() -> Bool {
        nativeFocusMode() == "noWindowsAxActivateClickFallback" || RuntimeFlags.nativeFocusClickFallbackEnabled
    }

    private func scheduleNativeClickFallback(_ targetWid: CGWindowID, _ generation: Int64) {
        let delayMs = max(40, RuntimeFlags.nativeFocusClickFallbackDelayMs)
        BackgroundWork.zOrderCacheQueue.addOperationAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            guard Windows.isCurrentZOrderFocusGeneration(generation), let self else { return }
            guard Self.nativeTopWindowId() != targetWid else {
                Windows.requestZOrderCacheRefresh(full: false, delayMs: 0, topOnly: true)
                return
            }
            let startedAt = CFAbsoluteTimeGetCurrent()
            let result = self.postNativeTitlebarClick(targetWid)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            Diagnostics.log("AXFOCUS", String(format: "wid=%u source=hidClickFallback delay=%dms posted=%@ reason=%@ point=%@ total=%.1fms", targetWid, delayMs, result.posted ? "true" : "false", result.reason, result.pointText, elapsedMs))
            if result.posted {
                Windows.requestZOrderTopReview(reason: "hid-click-fallback", wid: targetWid, secondDelayMs: 80)
            } else {
                Windows.retryNativeFocusTargetIfNeeded(targetWid: targetWid, targetPid: self.application.pid, delayMs: 0)
            }
        }
    }

    private func scheduleNoWindowsAxActivateRetries(_ targetWid: CGWindowID, _ generation: Int64) {
        for delayMs in [100, 250] {
            BackgroundWork.focusActionsQueue.addOperationAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard Windows.isCurrentZOrderFocusGeneration(generation), let self else { return }
                self.retryNoWindowsAxActivate(targetWid, generation, delayMs)
            }
        }
    }

    private func retryNoWindowsAxActivate(_ targetWid: CGWindowID, _ generation: Int64, _ delayMs: Int) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        var psn = ProcessSerialNumber()
        GetProcessForPID(application.pid, &psn)
        _SLPSSetFrontProcessWithOptions(&psn, targetWid, SLPSMode.noWindows.rawValue)
        guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
        let activateOk = application.runningApplication.activate(options: [])
        let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        Diagnostics.log("AXFOCUS", String(format: "wid=%u source=noWindowsActivateRetry delay=%dms activateOk=%@ total=%.1fms", targetWid, delayMs, activateOk ? "true" : "false", ms))
    }

    private func nativeAxTarget(_ targetWid: CGWindowID) -> AXUIElement? {
        if let axUiElement, (try? axUiElement.cgWindowId()) == targetWid {
            return axUiElement
        }
        return Self.resolveNativeFocusAxElement(pid: application.pid, wid: targetWid, timeout: 0.25) ?? axUiElement
    }

    private func setNativeAxMainAndFocused(_ axUiElement: AXUIElement?) -> (main: AXError, focus: AXError) {
        guard let axUiElement else { return (.failure, .failure) }
        let timeout = nativeMultiWindowAxTimeout()
        AXUIElementSetMessagingTimeout(axUiElement, timeout)
        let mainErr = AXUIElementSetAttributeValue(axUiElement, kAXMainAttribute as CFString, kCFBooleanTrue)
        guard let appAx = application.axUiElement else { return (mainErr, .failure) }
        AXUIElementSetMessagingTimeout(appAx, timeout)
        let focusErr = AXUIElementSetAttributeValue(appAx, kAXFocusedWindowAttribute as CFString, axUiElement)
        return (mainErr, focusErr)
    }

    private func postSkyLightFocusClick(_ targetWid: CGWindowID) -> Bool {
        guard let bounds = skyLightClickBounds() else { return false }
        let point = skyLightClickPoint(bounds)
        let localPoint = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
        guard let down = skyLightMouseEvent(.leftMouseDown, targetWid, point, localPoint, 1),
              let up = skyLightMouseEvent(.leftMouseUp, targetWid, point, localPoint, 1) else { return false }
        Windows.noteSyntheticFocusClick()
        SLEventPostToPid(application.pid, down)
        usleep(1_000)
        SLEventPostToPid(application.pid, up)
        return true
    }

    func postSkyLightFocusClickForZRepair(_ targetWid: CGWindowID) -> Bool {
        postSkyLightFocusClick(targetWid)
    }

    private func skyLightMouseEvent(_ type: NSEvent.EventType, _ targetWid: CGWindowID, _ point: CGPoint, _ localPoint: CGPoint, _ clickCount: Int) -> CGEvent? {
        guard let nsEvent = NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: Int(targetWid), context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1.0),
              let event = nsEvent.cgEvent else { return nil }
        event.location = point
        event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        event.setIntegerValueField(.mouseEventSubtype, value: 3)
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(targetWid))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(targetWid))
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(application.pid))
        CGEventSetWindowLocation(event, localPoint)
        SLEventSetIntegerValueField(event, 40, Int64(application.pid))
        event.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        return event
    }

    private func skyLightClickBounds() -> CGRect? {
        guard let cgWindowId,
              let window = CGWindow.windows(.optionOnScreenOnly).first(where: { $0.id() == cgWindowId }),
              let bounds = window.bounds() else {
            if let position, let size {
                return CGRect(origin: position, size: size)
            }
            return nil
        }
        return bounds
    }

    private func skyLightClickPoint(_ bounds: CGRect) -> CGPoint {
        let x = bounds.minX + min(120, max(bounds.width - 24, 24))
        let y = bounds.minY + min(18, max(10, bounds.height * 0.03))
        return CGPoint(x: x, y: y)
    }

    private struct NativeClickResult {
        let posted: Bool
        let reason: String
        let point: CGPoint?
        var pointText: String { point.map { "\(Int($0.x)),\(Int($0.y))" } ?? "nil" }
    }

    private static let nativeClickOwnerBlocklist: Set<String> = [
        "Window Server",
        "Control Center",
        "Dock",
        "AltTab",
        "Notification Center",
        "SystemUIServer",
        "Spotlight",
        "Menubar",
        "Wallpaper",
        "CursorUIViewService",
        "UserNotificationCenter",
        "LocalAuthenticationRemoteService",
    ]

    private static let nativeClickTransparentOwnerBlocklist: Set<String> = [
        "Window Server",
        "Control Center",
        "Dock",
        "Notification Center",
        "SystemUIServer",
        "Spotlight",
        "Menubar",
        "Wallpaper",
        "CursorUIViewService",
        "UserNotificationCenter",
        "LocalAuthenticationRemoteService",
    ]

    private func postNativeTitlebarClick(_ targetWid: CGWindowID) -> NativeClickResult {
        guard NSEvent.pressedMouseButtons == 0 else { return NativeClickResult(posted: false, reason: "mouse-down", point: nil) }
        guard let candidate = nativeTitlebarClickCandidate(targetWid) else { return NativeClickResult(posted: false, reason: "no-exposed-point", point: nil) }
        let localPoint = CGPoint(x: candidate.point.x - candidate.bounds.minX, y: candidate.point.y - candidate.bounds.minY)
        guard let down = skyLightMouseEvent(.leftMouseDown, targetWid, candidate.point, localPoint, 1),
              let up = skyLightMouseEvent(.leftMouseUp, targetWid, candidate.point, localPoint, 1) else {
            return NativeClickResult(posted: false, reason: "event-create", point: candidate.point)
        }
        Windows.noteSyntheticFocusClick()
        SLEventPostToPid(application.pid, down)
        usleep(1_000)
        SLEventPostToPid(application.pid, up)
        return NativeClickResult(posted: true, reason: "slevent-pid", point: candidate.point)
    }

    private func nativeTitlebarClickCandidate(_ targetWid: CGWindowID) -> (point: CGPoint, bounds: CGRect)? {
        let windows = CGWindow.windows(.optionOnScreenOnly)
        guard let target = windows.first(where: { $0.id() == targetWid }),
              target.ownerPID() == application.pid,
              target.layer() == 0,
              let bounds = target.bounds(),
              bounds.width >= 120,
              bounds.height >= 80 else { return nil }
        let y = bounds.minY + min(18, max(10, bounds.height * 0.03))
        for x in nativeTitlebarClickXOffsets(bounds.width).map({ bounds.minX + $0 }) {
            let point = CGPoint(x: x, y: y)
            guard Self.nativePointOnDisplay(point) else { continue }
            if Self.nativeTopRoutableWindow(at: point, in: windows) == targetWid {
                return (point, bounds)
            }
        }
        return nil
    }

    private func nativeTitlebarClickXOffsets(_ width: CGFloat) -> [CGFloat] {
        [120, 160, 220, 300, width / 2, width - 160, width - 80].map { min(max($0, 20), width - 20) }
    }

    private static func nativeTopWindowId() -> CGWindowID? {
        CGWindow.windows(.optionOnScreenOnly).first(where: { nativeVisibleWindow($0) })?.id()
    }

    private static func nativeWindowBlocksClick(_ window: CGWindow, _ point: CGPoint) -> Bool {
        guard nativeVisibleWindow(window), let bounds = window.bounds() else { return false }
        return bounds.contains(point)
    }

    private static func nativeTopRoutableWindow(at point: CGPoint, in windows: [CGWindow]) -> CGWindowID? {
        windows.first(where: { nativeRoutableWindow($0, point) })?.id()
    }

    private static func nativeRoutableWindow(_ window: CGWindow, _ point: CGPoint) -> Bool {
        guard let owner = window.ownerName(),
              !nativeClickTransparentOwnerBlocklist.contains(owner),
              nativeWindowAlpha(window) >= 0.1,
              let bounds = window.bounds(),
              bounds.width >= 10,
              bounds.height >= 10 else { return false }
        return bounds.contains(point)
    }

    private static func nativeVisibleWindow(_ window: CGWindow) -> Bool {
        guard window.layer() == 0,
              let owner = window.ownerName(),
              !nativeClickOwnerBlocklist.contains(owner),
              let bounds = window.bounds(),
              bounds.width >= 40,
              bounds.height >= 40,
              nativeWindowAlpha(window) >= 0.1 else { return false }
        return true
    }

    private static func nativeWindowAlpha(_ window: CGWindow) -> Double {
        window[kCGWindowAlpha] as? Double ?? 1.0
    }

    private static func nativePointOnDisplay(_ point: CGPoint) -> Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return true }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return true }
        return displays.prefix(Int(count)).contains { CGDisplayBounds($0).contains(point) }
    }

    private func focusNativeMacWindowOriginalAltTab(_ generation: Int64, _ enqueuedAt: CFAbsoluteTime, _ preZ: [Windows.PreZEntry]) {
        guard Windows.isCurrentZOrderFocusGeneration(generation), let targetWid = cgWindowId else { return }
        let startedAt = CFAbsoluteTimeGetCurrent()
        let wasAlreadyFrontmost = Applications.frontmostPid == application.pid || NSWorkspace.shared.frontmostApplication?.processIdentifier == application.pid
        var psn = ProcessSerialNumber()
        GetProcessForPID(application.pid, &psn)
        _SLPSSetFrontProcessWithOptions(&psn, targetWid, SLPSMode.userGenerated.rawValue)
        let slpsAt = CFAbsoluteTimeGetCurrent()
        Diagnostics.markSwitchPhase("slpsDone", extra: "originalInline")
        makeKeyWindow(&psn)
        let makeKeyAt = CFAbsoluteTimeGetCurrent()
        Diagnostics.markSwitchPhase("makeKeyDone", extra: "originalInline")
        let orderErr = CGSOrderWindow(CGS_CONNECTION, targetWid, CGSWindowOrderingMode.above.rawValue, 0)
        let orderAt = CFAbsoluteTimeGetCurrent()
        Diagnostics.markSwitchPhase("cgsOrderDone", extra: "originalInline err=\(orderErr.rawValue)")
        if wasAlreadyFrontmost && orderErr != .success {
            focusNativeWindowViaAx(targetWid, phase: nil)
            let finishedAt = CFAbsoluteTimeGetCurrent()
            Diagnostics.log("AXFOCUS", String(format: "wid=%u source=originalInline-sync queue=%.1fms slps=%.1fms makeKey=%.1fms cgs=%.1fms cgsErr=%d ax=%.1fms total=%.1fms endToEnd=%.1fms", targetWid, (startedAt - enqueuedAt) * 1000, (slpsAt - startedAt) * 1000, (makeKeyAt - slpsAt) * 1000, (orderAt - makeKeyAt) * 1000, orderErr.rawValue, (finishedAt - orderAt) * 1000, (finishedAt - startedAt) * 1000, (finishedAt - enqueuedAt) * 1000))
            manuallyUpdateFocusOrderForDirectFocus()
            Windows.armNativeFocusZOrderIntent(for: self, preZ: preZ)
            scheduleNativeAxFocusVerification(targetWid, generation)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
                Windows.previewSelectedWindowIfNeeded()
                Windows.requestZOrderTopReview(reason: "native-original-inline-sync", wid: targetWid)
            }
            return
        }
        manuallyUpdateFocusOrderForDirectFocus()
        Windows.armNativeFocusZOrderIntent(for: self, preZ: preZ)
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            guard Windows.isCurrentZOrderFocusGeneration(generation), let self, let targetWid = self.cgWindowId else { return }
            let axStartedAt = CFAbsoluteTimeGetCurrent()
            let queueWaitMs = (axStartedAt - enqueuedAt) * 1000
            self.focusNativeWindowViaAx(targetWid, phase: nil)
            let finishedAt = CFAbsoluteTimeGetCurrent()
            Diagnostics.log("AXFOCUS", String(format: "wid=%u source=originalInline-async queue=%.1fms slps=%.1fms makeKey=%.1fms cgs=%.1fms cgsErr=%d ax=%.1fms total=%.1fms endToEnd=%.1fms", targetWid, queueWaitMs, (slpsAt - startedAt) * 1000, (makeKeyAt - slpsAt) * 1000, (orderAt - makeKeyAt) * 1000, orderErr.rawValue, (finishedAt - axStartedAt) * 1000, (finishedAt - startedAt) * 1000, (finishedAt - enqueuedAt) * 1000))
            Diagnostics.markSwitchPhase("axDone", extra: "originalInline wid=\(targetWid)")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
                Windows.previewSelectedWindowIfNeeded()
                Windows.requestZOrderTopReview(reason: "native-original-inline", wid: targetWid)
            }
        }
        scheduleNativeAxFocusVerification(targetWid, generation)
    }

    private func nativeFocusMode() -> String {
        if let mode = UserDefaults.standard.string(forKey: "nativeFocusMode") {
            if mode == "original" || mode == "skyLightEventFocus" { return mode }
            guard RuntimeFlags.nativeExperimentalFocusModesEnabled else { return "original" }
            return mode
        }
        return "original"
    }

    private func focusNativeMultiWindow(_ psn: inout ProcessSerialNumber, _ targetWid: CGWindowID, _ preZ: [Windows.PreZEntry]) {
        if shouldUseNoWindowsNativeFocus() {
            focusNativeMultiWindowNoWindows(&psn, targetWid, preZ)
        } else {
            focusNativeMultiWindowUserGenerated(&psn, targetWid, preZ)
        }
    }

    private func focusNativeMultiWindowNoWindows(_ psn: inout ProcessSerialNumber, _ targetWid: CGWindowID, _ preZ: [Windows.PreZEntry]) {
        _SLPSSetFrontProcessWithOptions(&psn, targetWid, SLPSMode.noWindows.rawValue)
        Diagnostics.markSwitchPhase("slpsDone", extra: "nativeMultiWindow noWindows")
        makeKeyWindow(&psn)
        Diagnostics.markSwitchPhase("makeKeyDone", extra: "nativeMultiWindow")
        let orderErr = orderNativeTargetAboveBlocker(targetWid, preZ)
        Diagnostics.markSwitchPhase("cgsOrderDone", extra: "nativeMultiWindow err=\(orderErr.rawValue)")
        let generation = Windows.currentZOrderFocusGeneration()
        let syncAx = shouldSynchronouslyFocusNativeWindow()
        if syncAx {
            focusNativeWindowViaAx(targetWid, phase: "axSyncDone")
        }
        manuallyUpdateFocusOrderForDirectFocus()
        Windows.armNativeFocusZOrderIntent(for: self, preZ: preZ)
        if !syncAx {
            let axCompleted = queueNativeWindowAxFocus(targetWid, generation)
            if !axCompleted {
                forceNativeWindowFrontAfterAxTimeout(&psn, targetWid)
            }
        }
        Windows.retryNativeFocusTargetIfNeeded(targetWid: targetWid, targetPid: application.pid, delayMs: 160)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
            Windows.previewSelectedWindowIfNeeded()
        }
    }

    private func focusNativeMultiWindowUserGenerated(_ psn: inout ProcessSerialNumber, _ targetWid: CGWindowID, _ preZ: [Windows.PreZEntry]) {
        _SLPSSetFrontProcessWithOptions(&psn, targetWid, SLPSMode.noWindows.rawValue)
        Diagnostics.markSwitchPhase("slpsDone", extra: "nativeMultiWindow noWindows makeKey asyncRaise")
        makeKeyWindow(&psn)
        Diagnostics.markSwitchPhase("makeKeyDone", extra: "nativeMultiWindow noWindows asyncRaise")
        let orderErr = orderNativeTargetAboveBlocker(targetWid, preZ)
        Diagnostics.markSwitchPhase("cgsOrderDone", extra: "nativeMultiWindow noWindows asyncRaise err=\(orderErr.rawValue)")
        manuallyUpdateFocusOrderForDirectFocus()
        Windows.armNativeFocusZOrderIntent(for: self, preZ: preZ)
        if queueNativeWindowAxRaise(targetWid) {
            observeNativeTargetAtZ0Async(targetWid)
        } else {
            raiseNativeWindowViaAx(targetWid, phase: "axRaiseDone")
        }
        Windows.retryNativeFocusTargetIfNeeded(targetWid: targetWid, targetPid: application.pid, delayMs: 120)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
            Windows.previewSelectedWindowIfNeeded()
        }
    }

    private func shouldUseNoWindowsNativeFocus() -> Bool {
        guard RuntimeFlags.nativeNoWindowsFocusEnabled else { return false }
        guard let bundleIdentifier = application.bundleIdentifier else { return false }
        return ["com.apple.Terminal", "com.googlecode.iterm2"].contains(bundleIdentifier)
    }

    /// Whether to focus via the per-window `noWindows` SLPS path (raises ONLY
    /// the target window) instead of the app-activating `.userGenerated`
    /// original path. Broadened from the Terminal/iTerm2-only
    /// `shouldUseNoWindowsNativeFocus()` allowlist to every native window, so
    /// multi-window apps (Outlook, Safari, …) stop raising all their windows
    /// on focus — the cause of the `SAMEAPP`>1 z-order / recency corruption.
    ///
    /// The synchronous-AX (`shouldSynchronouslyFocusNativeWindow`) and AX
    /// prewarm decisions intentionally stay on the narrow terminal allowlist:
    /// non-terminal apps therefore take `focusNativeMultiWindowUserGenerated`
    /// (which *also* uses noWindows SLPS — no sibling raise — but focuses via
    /// async AX), so a slow AX app like Outlook never blocks the main thread.
    private func shouldUsePerWindowNativeFocus() -> Bool {
        guard RuntimeFlags.nativeNoWindowsFocusEnabled else { return false }
        guard cgWindowId != nil, !isWindowlessApp, !isParallelsCoherenceWindow else { return false }
        return application.bundleIdentifier != nil
    }

    private func shouldSynchronouslyFocusNativeWindow() -> Bool {
        shouldUseNoWindowsNativeFocus()
    }

    private func nativeMultiWindowAsyncAxWaitMs() -> Int {
        let value = UserDefaults.standard.object(forKey: "nativeMultiWindowAsyncAxWaitMs") as? Int ?? 180
        return min(max(value, 0), 300)
    }

    private func nativeMultiWindowZWaitMs() -> Int {
        let value = UserDefaults.standard.object(forKey: "nativeMultiWindowZWaitMs") as? Int ?? 850
        return min(max(value, 0), 1200)
    }

    private func nativeMultiWindowAxTimeout() -> Float {
        let value = UserDefaults.standard.object(forKey: "nativeMultiWindowAxTimeoutMs") as? Int ?? 50
        return Float(min(max(value, 50), 1000)) / 1000
    }

    private func orderNativeTargetAboveBlocker(_ targetWid: CGWindowID, _ preZ: [Windows.PreZEntry]) -> CGError {
        if let blockerWid = preZ.first(where: { $0.wid != targetWid })?.wid {
            let pairErr = CGSOrderWindow(CGS_CONNECTION, targetWid, CGSWindowOrderingMode.above.rawValue, blockerWid)
            if pairErr == .success { return pairErr }
        }
        return CGSOrderWindow(CGS_CONNECTION, targetWid, CGSWindowOrderingMode.above.rawValue, 0)
    }

    private func focusNativeWindowViaAx(_ targetWid: CGWindowID, phase: String?) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard let target = nativeFocusAxElement(targetWid) else { return }
        let afterSetAt: CFAbsoluteTime
        if let appAx = application.axUiElement {
            let timeout = nativeMultiWindowAxTimeout()
            AXUIElementSetMessagingTimeout(appAx, timeout)
            AXUIElementSetMessagingTimeout(target.axElement, timeout)
            try? appAx.setAttribute(kAXFocusedWindowAttribute, target.axElement)
            afterSetAt = CFAbsoluteTimeGetCurrent()
        } else {
            afterSetAt = CFAbsoluteTimeGetCurrent()
        }
        try? target.axElement.focusWindow()
        let finishedAt = CFAbsoluteTimeGetCurrent()
        Diagnostics.log("AXFOCUS", String(format: "wid=%u source=%@ age=%.0fms set=%.1fms raise=%.1fms total=%.1fms", targetWid, target.source, target.ageMs, (afterSetAt - startedAt) * 1000, (finishedAt - afterSetAt) * 1000, (finishedAt - startedAt) * 1000))
        if let phase {
            Diagnostics.markSwitchPhase(phase, extra: String(format: "nativeMultiWindow wid=%u ax=%.1fms", targetWid, (finishedAt - startedAt) * 1000))
        }
    }

    private func scheduleNativeAxFocusVerification(_ targetWid: CGWindowID, _ generation: Int64) {
        for delayMs in [60, 180, 420] {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
                guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
                guard Windows.captureTopZRanking(maxCount: 1).first?.wid == targetWid else { return }
                BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
                    guard Windows.isCurrentZOrderFocusGeneration(generation), let self else { return }
                    let focusedWid = self.nativeFocusedWindowId()
                    guard focusedWid != targetWid else { return }
                    self.focusNativeWindowViaAx(targetWid, phase: nil)
                    Diagnostics.log("AXFOCUS", "wid=\(targetWid) source=nativeAxVerify delay=\(delayMs)ms focusedWas=#\(focusedWid ?? 0) corrected=true")
                }
            }
        }
    }

    private func nativeFocusedWindowId() -> CGWindowID? {
        guard let appAx = application.axUiElement else { return nil }
        AXUIElementSetMessagingTimeout(appAx, 0.05)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(appAx, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused else { return nil }
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(focused as! AXUIElement, &wid) == .success else { return nil }
        return wid
    }

    private func raiseNativeWindowViaAx(_ targetWid: CGWindowID, phase: String?) {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard let target = nativeFocusAxElement(targetWid) else { return }
        AXUIElementSetMessagingTimeout(target.axElement, nativeMultiWindowAxTimeout())
        try? target.axElement.performAction(kAXRaiseAction as String)
        let finishedAt = CFAbsoluteTimeGetCurrent()
        Diagnostics.log("AXRAISE", String(format: "wid=%u source=%@ age=%.0fms raise=%.1fms", targetWid, target.source, target.ageMs, (finishedAt - startedAt) * 1000))
        if let phase {
            Diagnostics.markSwitchPhase(phase, extra: String(format: "nativeMultiWindow wid=%u axRaise=%.1fms", targetWid, (finishedAt - startedAt) * 1000))
        }
    }

    private func queueNativeWindowAxRaise(_ targetWid: CGWindowID) -> Bool {
        guard let target = nativeFocusAxElement(targetWid) else { return false }
        let generation = Windows.currentZOrderFocusGeneration()
        let timeout = nativeMultiWindowAxTimeout()
        BackgroundWork.accessibilityCommandsQueue.addOperation {
            guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
            let startedAt = CFAbsoluteTimeGetCurrent()
            let axTarget = target
            let resolvedAt = CFAbsoluteTimeGetCurrent()
            guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
            AXUIElementSetMessagingTimeout(axTarget.axElement, timeout)
            try? axTarget.axElement.performAction(kAXRaiseAction as String)
            let finishedAt = CFAbsoluteTimeGetCurrent()
            Diagnostics.log("AXRAISE", String(format: "wid=%u source=%@ age=%.0fms resolve=%.1fms raise=%.1fms async=true", targetWid, axTarget.source, axTarget.ageMs, (resolvedAt - startedAt) * 1000, (finishedAt - resolvedAt) * 1000))
        }
        return true
    }

    private func observeNativeTargetAtZ0Async(_ targetWid: CGWindowID) {
        let maxMs = nativeMultiWindowZWaitMs()
        let generation = Windows.currentZOrderFocusGeneration()
        let startedAt = CFAbsoluteTimeGetCurrent()
        Windows.requestZOrderTopReview(reason: "native-z-observe", wid: targetWid, secondDelayMs: min(maxMs, 120))
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(maxMs)) {
            guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
            let topWid = Windows.cachedTopZOrderWid(maxAgeMs: 200)
            let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            Diagnostics.log("ZWAIT", String(format: "wid=%u top=%u wait=%.1fms max=%d async=true cached=true", targetWid, topWid ?? 0, ms, maxMs))
            if topWid == targetWid {
                Windows.requestZOrderCacheRefresh(full: false)
            }
        }
    }

    func prewarmNativeFocusAxElementIfNeeded() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.prewarmNativeFocusAxElementIfNeeded() }
            return
        }
        guard BackgroundWork.focusPrewarmQueue != nil else { return }
        guard shouldPrewarmNativeFocusAxElement(), let targetWid = cgWindowId else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let ttl = nativeFocusAxPrewarmTtl()
        if fastFocusAxElementWid == targetWid && fastFocusAxElement != nil && now - fastFocusAxElementAt < ttl { return }
        if fastFocusAxPrewarmInFlight || now - fastFocusAxLastAttemptAt < 5 { return }
        fastFocusAxPrewarmInFlight = true
        fastFocusAxLastAttemptAt = now
        let targetPid = application.pid
        let timeout = nativeMultiWindowAxTimeout()
        BackgroundWork.focusPrewarmQueue.addOperation { [weak self] in
            let startedAt = CFAbsoluteTimeGetCurrent()
            let resolvedAxElement = Self.resolveNativeFocusAxElement(pid: targetPid, wid: targetWid, timeout: timeout)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.fastFocusAxPrewarmInFlight = false
                guard self.cgWindowId == targetWid else { return }
                if let resolvedAxElement {
                    self.fastFocusAxElement = resolvedAxElement
                    self.fastFocusAxElementWid = targetWid
                    self.fastFocusAxElementAt = CFAbsoluteTimeGetCurrent()
                }
                let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                Diagnostics.log("AXPREWARM", String(format: "wid=%u found=%@ ms=%.1f", targetWid, resolvedAxElement == nil ? "false" : "true", ms))
            }
        }
    }

    private func shouldPrewarmNativeFocusAxElement() -> Bool {
        guard cgWindowId != nil, !isWindowlessApp, !isParallelsCoherenceWindow else { return false }
        guard Windows.visibleWindowCount(pid: application.pid) > 1 else { return false }
        return !shouldUseNoWindowsNativeFocus()
    }

    private func nativeFocusAxElement(_ targetWid: CGWindowID) -> (axElement: AXUIElement, source: String, ageMs: Double)? {
        let now = CFAbsoluteTimeGetCurrent()
        if fastFocusAxElementWid == targetWid, let fastFocusAxElement, now - fastFocusAxElementAt < nativeFocusAxPrewarmTtl() {
            return (fastFocusAxElement, "prewarm", (now - fastFocusAxElementAt) * 1000)
        }
        guard let axUiElement else { return nil }
        return (axUiElement, "cached", -1)
    }

    private func nativeFocusAxPrewarmTtl() -> CFTimeInterval {
        let value = UserDefaults.standard.object(forKey: "nativeFocusAxPrewarmTtlMs") as? Int ?? 300_000
        return Double(min(max(value, 500), 300_000)) / 1000
    }

    private static func resolveNativeFocusAxElement(pid: pid_t, wid: CGWindowID, timeout: Float = 1) -> AXUIElement? {
        let deadline = CFAbsoluteTimeGetCurrent() + CFTimeInterval(timeout)
        let appAx = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appAx, timeout)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(appAx, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement] else { return nil }
        for axWindow in axWindows {
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            guard remaining > 0 else { return nil }
            AXUIElementSetMessagingTimeout(axWindow, Float(min(max(remaining, 0.02), CFTimeInterval(timeout))))
            if (try? axWindow.cgWindowId()) == wid { return axWindow }
        }
        return nil
    }

    private func forceNativeWindowFrontAfterAxTimeout(_ psn: inout ProcessSerialNumber, _ targetWid: CGWindowID) {
        _SLPSSetFrontProcessWithOptions(&psn, targetWid, SLPSMode.userGenerated.rawValue)
        Diagnostics.markSwitchPhase("slpsFallbackDone", extra: "nativeMultiWindow wid=\(targetWid)")
        makeKeyWindow(&psn)
        Diagnostics.markSwitchPhase("makeKeyFallbackDone", extra: "nativeMultiWindow wid=\(targetWid)")
        _ = CGSOrderWindow(CGS_CONNECTION, targetWid, CGSWindowOrderingMode.above.rawValue, 0)
    }

    private func queueNativeWindowAxFocus(_ targetWid: CGWindowID, _ generation: Int64) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            defer { semaphore.signal() }
            guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
            guard let self else { return }
            Diagnostics.markSwitchPhase("axQueueEntry", extra: "nativeMultiWindow wid=\(targetWid)")
            self.focusNativeWindowViaAx(targetWid, phase: nil)
            Diagnostics.markSwitchPhase("axDone", extra: "nativeMultiWindow wid=\(targetWid)")
        }
        let waitMs = nativeMultiWindowAsyncAxWaitMs()
        guard waitMs > 0 else { return false }
        if semaphore.wait(timeout: .now() + .milliseconds(waitMs)) == .success {
            Diagnostics.markSwitchPhase("axBoundedWaitDone", extra: "nativeMultiWindow wait=\(waitMs)ms wid=\(targetWid)")
            return true
        } else {
            Diagnostics.markSwitchPhase("axBoundedWaitTimeout", extra: "nativeMultiWindow wait=\(waitMs)ms wid=\(targetWid)")
            return false
        }
    }

    private func queueNativeWindowAxFocusAsync(_ targetWid: CGWindowID, _ generation: Int64) {
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
            guard let self else { return }
            Diagnostics.markSwitchPhase("axQueueEntry", extra: "nativeMultiWindow async wid=\(targetWid)")
            self.focusNativeWindowViaAx(targetWid, phase: nil)
            Diagnostics.markSwitchPhase("axDone", extra: "nativeMultiWindow async wid=\(targetWid)")
        }
    }

    private func manuallyUpdateFocusOrderForDirectFocus() {
        application.focusedWindow = self
        Applications.frontmostPid = application.pid
        App.lastFocusedTargetWid = cgWindowId
        App.lastFocusedTargetPid = application.pid
        App.lastFocusedTargetTime = CFAbsoluteTimeGetCurrent()
        guard !App.appIsBeingUsed else {
            _ = Windows.updateLastFocusOrder(self)
            return
        }
        App.noteDirectFocusOutsideAltTab(cgWindowId)
        if let windows = Windows.updateLastFocusOrder(self) {
            App.refreshOpenUiAfterExternalEvent(windows)
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

    private func isInboundFromParallelsCoherence() -> Bool {
        guard application.isParallelsCoherence else { return false }
        let sourcePid = App.sessionSourcePid ?? Applications.frontmostPid
        guard let sourcePid, sourcePid != application.pid,
              let sourceApp = Applications.list.first(where: { $0.pid == sourcePid }) else { return false }
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
    /// intentionally omitted here. When the target is a multi-window app
    /// like Terminal, the fake event can promote every sibling window in
    /// that process above the Parallels source. `CGSOrderWindow` can't
    /// repair that afterwards on current macOS (`err=1000`), so avoid
    /// creating the sibling stack in the first place.
    private func focusMacOsWindowOverParallelsCoherence() {
        Diagnostics.log("FOCUS", "enter focusMacOsWindowOverParallelsCoherence target=\(debugId ?? "?")")
        guard let targetWid = cgWindowId else { return }
        let preZ = Windows.zOrderSnapshotForFocus()
        Windows.armAltTabFocusGuard(for: self)
        var psn = ProcessSerialNumber()
        GetProcessForPID(application.pid, &psn)
        if shouldPostParToMacSyntheticClick() {
            let skyLightPosted = postSkyLightFocusClick(targetWid)
            Diagnostics.markSwitchPhase("skyLightClickDone", extra: "parToMac posted=\(skyLightPosted) wid=\(targetWid)")
        } else if RuntimeFlags.parToMacSyntheticClickEnabled {
            Diagnostics.markSwitchPhase("skyLightClickSkipped", extra: "parToMac unsafe bundle=\(application.bundleIdentifier ?? "?") wid=\(targetWid)")
        }
        // Per-window mode (like the native path): `.noWindows` makes the target
        // app frontmost with `targetWid` as key WITHOUT raising the app's other
        // windows, so a multi-window Mac target (Outlook, Safari, …) focused out
        // of Coherence raises ONLY the target — the same SAMEAPP>1 / recency fix
        // as shouldUsePerWindowNativeFocus. `.userGenerated` (which raises the
        // app's windows) stays the fallback when per-window focus is disabled.
        // makeKeyWindow stays omitted; armNativeFocusZOrderIntent +
        // retryNativeFocusTargetIfNeeded below re-assert the target if Parallels
        // re-raises its Coherence window.
        let perWindowParToMac = shouldUsePerWindowNativeFocus()
        let parToMacSlpsMode: SLPSMode = perWindowParToMac ? .noWindows : .userGenerated
        _SLPSSetFrontProcessWithOptions(&psn, targetWid, parToMacSlpsMode.rawValue)
        Diagnostics.markSwitchPhase("slpsDone", extra: "parToMac mode=\(perWindowParToMac ? "noWindows" : "userGenerated")")
        try? axUiElement?.focusWindow()
        Diagnostics.markSwitchPhase("axSyncDone", extra: "parToMac wid=\(targetWid)")
        let orderErr = CGSOrderWindow(CGS_CONNECTION, targetWid, CGSWindowOrderingMode.above.rawValue, 0)
        Diagnostics.markSwitchPhase("cgsOrderDone", extra: "parToMac err=\(orderErr.rawValue)")
        Diagnostics.log("FOCUS", "Par→mac: SLPS(\(perWindowParToMac ? "noWindows" : "userGenerated"))+AX focus(wid=\(targetWid)) done")
        Windows.armNativeFocusZOrderIntent(for: self, preZ: preZ)
        Windows.retryNativeFocusTargetIfNeeded(targetWid: targetWid, targetPid: application.pid, delayMs: 40)
        snapshotTopWindowsForParMac(label: "Par→mac+0ms", targetWid: targetWid)
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            self?.snapshotTopWindowsForParMac(label: "Par→mac+30ms", targetWid: targetWid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            self?.snapshotTopWindowsForParMac(label: "Par→mac+100ms", targetWid: targetWid)
        }
        manuallyUpdateFocusOrderForParallelsTransition()
        repokeFrontmostForCachedListeners(generation: Windows.currentZOrderFocusGeneration())
    }

    private func shouldPostParToMacSyntheticClick() -> Bool {
        guard RuntimeFlags.parToMacSyntheticClickEnabled else { return false }
        guard let bundleIdentifier = application.bundleIdentifier else { return true }
        return !Self.parToMacSyntheticClickUnsafeBundlePrefixes.contains { bundleIdentifier.hasPrefix($0) }
    }

    private static let parToMacSyntheticClickUnsafeBundlePrefixes = [
        "com.microsoft.edgemac",
        "com.google.Chrome",
        "com.brave.Browser",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.operasoftware.Opera",
        "com.vivaldi.Vivaldi",
        "company.thebrowser.Browser",
    ]

    /// Diagnostic: top-8 z-order with per-window owner+wid+level. Lets us
    /// see exactly which app's windows surface above the target after a
    /// Par→Mac transition. Same shape as ZENFORCE's SYSZ but at .info
    /// level so it shows up at default log level, scoped to this path.
    private func snapshotTopWindowsForParMac(label: String, targetWid: CGWindowID) {
        guard Diagnostics.shouldLog("PARMAC") else { return }
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return }
        let skip: Set<String> = ["Window Server", "Control Center", "Dock", "AltTab", "Notification Center", "SystemUIServer", "Spotlight", "Menubar", "Wallpaper", "CursorUIViewService", "UserNotificationCenter", "LocalAuthenticationRemoteService"]
        var rows = [String]()
        var pos = 0
        var targetPos = -1
        var siblingCount = 0
        let targetOwner = application.bundleIdentifier ?? "?"
        for w in info {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            if skip.contains(owner) { continue }
            let wid = CGWindowID((w[kCGWindowNumber as String] as? Int) ?? 0)
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            let name = (w[kCGWindowName as String] as? String) ?? ""
            if pos < 8 { rows.append("z\(pos)=#\(wid) Lv\(layer) \(owner.prefix(10)):\(name.prefix(15))") }
            if wid == targetWid { targetPos = pos }
            if owner == "Terminal" || (application.localizedName != nil && owner == application.localizedName!) {
                siblingCount += 1
            }
            pos += 1
            if pos >= 24 { break }
        }
        Diagnostics.log("PARMAC", "\(label) target=#\(targetWid)(\(targetOwner.suffix(20))) atZ=\(targetPos) sameAppCount=\(siblingCount) topZ=[\(rows.joined(separator: " | "))]")
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
        let generation = Windows.currentZOrderFocusGeneration()
        let preZ = Windows.zOrderSnapshotForFocus()
        Windows.armAltTabFocusGuard(for: self, preZOverride: preZ)
        let guestPrefocusQueued = queueGuestPrefocus(generation: generation, targetWid: targetWid, label: "prefocus wid=\(targetWid)")
        if guestPrefocusQueued {
            usleep(useconds_t(max(0, min(RuntimeFlags.parGuestPrefocusHostDelayMs, 100)) * 1000))
        }
        var psn = ProcessSerialNumber()
        GetProcessForPID(application.pid, &psn)
        let startedAt = CFAbsoluteTimeGetCurrent()
        let useUserGenerated = RuntimeFlags.parallelsTargetUserGeneratedFocusEnabled || (RuntimeFlags.parSameBoundaryTargetUserGeneratedFocusEnabled && isInboundFromParallelsCoherence())
        let mode = useUserGenerated ? SLPSMode.userGenerated : SLPSMode.noWindows
        _SLPSSetFrontProcessWithOptions(&psn, targetWid, mode.rawValue)
        let slpsAt = CFAbsoluteTimeGetCurrent()
        makeKeyWindow(&psn)
        let makeKeyAt = CFAbsoluteTimeGetCurrent()
        Diagnostics.log("AXFOCUS", String(format: "wid=%u source=macToParImmediate mode=%@ slps=%.1fms makeKey=%.1fms main=%.1fms", targetWid, mode == .userGenerated ? "userGenerated" : "noWindows", (slpsAt - startedAt) * 1000, (makeKeyAt - slpsAt) * 1000, (makeKeyAt - startedAt) * 1000))
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
            guard let self else { return }
            let axStartedAt = CFAbsoluteTimeGetCurrent()
            var frontErr = AXError.failure
            if RuntimeFlags.parTargetAxFrontmostEnabled, let appAx = self.application.axUiElement {
                AXUIElementSetMessagingTimeout(appAx, 0.03)
                frontErr = AXUIElementSetAttributeValue(appAx, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            }
            let frontAt = CFAbsoluteTimeGetCurrent()
            if let windowAx = self.axUiElement {
                AXUIElementSetMessagingTimeout(windowAx, 0.03)
                try? windowAx.focusWindow()
            }
            let finishedAt = CFAbsoluteTimeGetCurrent()
            Diagnostics.log("AXFOCUS", String(format: "wid=%u source=macToParAsync front=%.1fms raise=%.1fms total=%.1fms frontErr=%d", targetWid, (frontAt - axStartedAt) * 1000, (finishedAt - frontAt) * 1000, (finishedAt - axStartedAt) * 1000, frontErr.rawValue))
        }
        manuallyUpdateFocusOrderForParallelsTransition()
        Windows.restoreExpectedZOrderForFocus(targetWid: targetWid, targetPid: application.pid, preZ: preZ)
        repokeFrontmostForCachedListeners(generation: generation)
    }

    @discardableResult
    private func queueGuestPrefocus(generation: Int64, targetWid: CGWindowID, label: String) -> Bool {
        guard RuntimeFlags.parGuestPrefocusEnabled, Winside.isEnabled, let title else { return false }
        let queuedAt = CFAbsoluteTimeGetCurrent()
        Diagnostics.markSwitchPhase("guestPrefocusQueued", extra: "wid=\(targetWid)")
        Winside.setForegroundForTitleMeasuredAsync(title, label: label, shouldProceed: {
            Windows.isCurrentZOrderFocusGeneration(generation) && (CFAbsoluteTimeGetCurrent() - queuedAt) * 1000 <= Double(RuntimeFlags.parGuestPrefocusMaxAgeMs)
        }) { result in
            let hwnd = result.hwnd.map(String.init) ?? "nil"
            Diagnostics.log("FOCUS", String(format: "guestPrefocusDone wid=%u ok=%@ hwnd=%@ total=%.1fms list=%.1fms set=%.1fms sinceQueue=%.1fms reason=%@", targetWid, result.ok ? "true" : "false", hwnd, result.elapsedMs, result.listMs, result.setMs, (CFAbsoluteTimeGetCurrent() - queuedAt) * 1000, result.reason))
        }
        return true
    }

    /// Re-fire `SLPS(.noWindows)` ~150ms after a focus transition so the
    /// NSWorkspaceDidActivateApplicationNotification gets a second
    /// definite hit. Other processes that cache the frontmost-app
    /// bundle ID — Karabiner-Elements being the concrete observed case
    /// for `frontmost_application_if` rules — sometimes miss the initial
    /// SLPS-triggered notification, so Cmd-key remaps don't fire until
    /// the user clicks the window manually. The repoke gives the cache
    /// a deterministic refresh trigger.
    ///
    /// Safe by construction: `SLPS(.noWindows)` activates the process
    /// without raising ANY windows (per the API table in
    /// `project_alttab_parallels.md`). It cannot bring other windows of
    /// this app — or any other app — forward. Skips if the user has
    /// switched away or target is not visually topmost.
    private func repokeFrontmostForCachedListeners(generation: Int64) {
        let targetPid = application.pid
        let targetWid = cgWindowId ?? 0
        for delayMs in [150, 450, 750, 1100] {
            scheduleFrontmostRepoke(delayMs: delayMs, generation: generation, targetPid: targetPid, targetWid: targetWid)
        }
    }

    private func scheduleFrontmostRepoke(delayMs: Int, generation: Int64, targetPid: pid_t, targetWid: CGWindowID) {
        // Parallels Coherence wraps the entire Windows app as a single
        // Mac wid (the shim window). SLPS(.noWindows) for that shim is
        // translated by Coherence to "activate the Windows app" on the
        // guest side, which raises the main app window above any
        // just-opened popup/child dialog — dismissing it. Native macOS
        // apps don't have this issue (SLPS.noWindows really is "no
        // windows"), but for Coherence we must skip repoke entirely.
        // Karabiner/NSWorkspace cache will refresh on the next genuine
        // user input.
        let isCoherence = application.isParallelsCoherence
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            if isCoherence {
                Diagnostics.log("FRONTMOSTSET", "+\(delayMs)ms repoke skipped Coherence app (would dismiss child popups) pid=\(targetPid) wid=\(targetWid)")
                return
            }
            guard Windows.isCurrentZOrderFocusGeneration(generation) else {
                Diagnostics.log("FRONTMOSTSET", "+\(delayMs)ms repoke skipped stale generation pid=\(targetPid) wid=\(targetWid)")
                return
            }
            guard !Windows.recentExternalKeyboardInputFollowsAltTabTarget(requireReleasable: true) else {
                Diagnostics.log("FRONTMOSTSET", "+\(delayMs)ms repoke skipped after keyboard input pid=\(targetPid) wid=\(targetWid)")
                return
            }
            guard Windows.captureTopZRanking(maxCount: 1).first?.wid == targetWid else {
                Diagnostics.log("FRONTMOSTSET", "+\(delayMs)ms repoke skipped target not z0 pid=\(targetPid) wid=\(targetWid)")
                return
            }
            let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            var psn = ProcessSerialNumber()
            GetProcessForPID(targetPid, &psn)
            _SLPSSetFrontProcessWithOptions(&psn, targetWid, SLPSMode.noWindows.rawValue)
            Diagnostics.log("FRONTMOSTSET", "+\(delayMs)ms repoke SLPS(noWin) pid=\(targetPid) wid=\(targetWid) wasFrontPid=\(frontPid ?? -1) for Karabiner/NSWorkspace cache")
            _ = self // silence weak self warning
        }
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
        application.focusedWindow = self
        Applications.frontmostPid = application.pid
        App.lastFocusedTargetWid = cgWindowId
        App.lastFocusedTargetPid = application.pid
        App.lastFocusedTargetTime = CFAbsoluteTimeGetCurrent()
        guard App.appIsBeingUsed else {
            App.noteDirectFocusOutsideAltTab(cgWindowId)
            if let windows = Windows.updateLastFocusOrder(self) {
                App.refreshOpenUiAfterExternalEvent(windows)
            }
            return
        }
        Windows.armAltTabFocusGuard(for: self)
        let source = sessionSourceWindow()
        let generation = Windows.currentZOrderFocusGeneration()
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
                guard Windows.isCurrentZOrderFocusGeneration(generation) else {
                    Diagnostics.log("MONITOR", "post-manualUpdate +\(delayMs)ms skipped stale generation target=#\(self.cgWindowId ?? 0) source=#\(source?.cgWindowId ?? 0)")
                    return
                }
                Diagnostics.logSystemZOrder("post-manualUpdate +\(delayMs)ms target=#\(self.cgWindowId ?? 0) source=#\(source?.cgWindowId ?? 0)")
                Diagnostics.logFrontmostSignals("post-manualUpdate +\(delayMs)ms")
                if let targetWid = self.cgWindowId {
                    Diagnostics.logFocusInvariant("post-manualUpdate +\(delayMs)ms", targetWid: targetWid, targetPid: self.application.pid, sourceWid: source?.cgWindowId, generation: generation)
                }
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
        let generation = Windows.currentZOrderFocusGeneration()
        manuallyUpdateFocusOrderForParallelsTransition()
        let targetWid = cgWindowId
        // kAXFrontmost setter: same rationale as in atomicallyPinAndActivate.
        // The same-process path doesn't fire SLPS — it goes purely
        // through AX. Without setting kAXFrontmost on the app, the
        // app-level "this window is on top" claim can lag and other
        // siblings of the same Parallels app can briefly assert
        // foreground. Cheap call; runs before the AX-raise.
        if RuntimeFlags.parTargetAxFrontmostEnabled, let appAx = application.axUiElement {
            let err = AXUIElementSetAttributeValue(appAx, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            Diagnostics.log("FRONTMOSTSET", "sameProcess kAXFrontmost=true pid=\(application.pid) wid=\(targetWid ?? 0) → \(err == .success ? "OK" : "err=\(err.rawValue)")")
        }
        if let targetWid {
            _ = queueGuestPrefocus(generation: generation, targetWid: targetWid, label: "sameProcess wid=\(targetWid)")
        }
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
            guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
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
        let generation = Windows.currentZOrderFocusGeneration()
        atomicallyPinAndActivate()
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) { [weak self] in
            guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
            guard let self else { return }
            BackgroundWork.accessibilityCommandsQueue.addOperation { [weak self] in
                guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
                guard let self else { return }
                try? self.axUiElement!.focusWindow()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                guard Windows.isCurrentZOrderFocusGeneration(generation) else { return }
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
        // Newly-created top-level windows often hit a race: AltTab's
        // AX `kAXWindowCreatedNotification` fires before WindowServer
        // has registered the new window with a space, so
        // CGSCopySpacesForWindows returns []. With `spaceIds = []`,
        // `isWindowInVisibleSpace` returns false → the window is
        // permanently filtered as "notInVisibleSpace" because nothing
        // re-triggers `updateSpaces` on a window the user can't see
        // to interact with. Default to the currently visible spaces so
        // the window appears in the panel; if/when AX fires another
        // event for this window, updateSpaces re-runs with the now-
        // populated CGS result.
        if spaceIds.isEmpty {
            spaceIds = Spaces.visibleSpaces
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
