import Cocoa
import ApplicationServices.HIServices.AXUIElement
import ApplicationServices.HIServices.AXNotificationConstants

class AccessibilityEvents {
    static let axObserverCallback: AXObserverCallback = { _, element, notificationName, _ in
        let type = notificationName as String
        Logger.debug { type }
        AXCallScheduler.shared.submit {
            do { try handleEvent(type, element) }
            catch { Logger.debug { "handleEvent threw for \(type): stale element" } }
        }
    }

    private static func handleEvent(_ type: String, _ element: AXUIElement) throws {
        let pid = try element.pid()
        Logger.debug { "\(type) pid:\(pid)" }
        if [kAXApplicationActivatedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification].contains(type) {
            AXCallScheduler.shared.schedule(key: "pid-\(pid)", context: "(pid:\(pid))", pid: pid) {
                try handleEventApp(type, pid, element)
            }
        } else {
            let wid = (try? element.cgWindowId()) ?? 0
            if type == kAXWindowCreatedNotification && wid == 0 {
                AXCallScheduler.shared.schedule(key: "pid-\(pid)", context: "(pid:\(pid))", pid: pid) {
                    try handleEventApp(type, pid, element)
                }
                return
            }
            guard wid != 0 || type == kAXUIElementDestroyedNotification,
                  wid != TilesPanel.shared.windowNumber else { return }
            if type == kAXUIElementDestroyedNotification {
                DispatchQueue.main.async {
                    Logger.info { "\(type) wid:\(wid) pid:\(pid)" }
                    windowDestroyed(element, pid, wid)
                }
                return
            }
            AXCallScheduler.shared.schedule(key: "wid-\(wid)", context: "(pid:\(pid) wid:\(wid))", pid: pid) {
                try handleEventWindow(type, wid, pid, element)
            }
        }
    }

    private static func handleEventApp(_ type: String, _ pid: pid_t, _ element: AXUIElement) throws {
        if type == kAXApplicationHiddenNotification || type == kAXApplicationShownNotification || type == kAXWindowCreatedNotification {
            DispatchQueue.main.async {
                Applications.appListUpdateThrottler.throttleOrProceed(key: "\(pid)") {
                    guard let app = Applications.findOrCreate(pid, false) else { return }
                    Logger.info { "\(type) app:\(app.debugId)" }
                    if type == kAXWindowCreatedNotification {
                        Applications.manuallyUpdateWindows(app)
                    } else {
                        applicationHiddenOrShown(app, pid, type)
                    }
                }
            }
            return
        }
        let attributes = try element.attributes([kAXFocusedWindowAttribute, kAXMainWindowAttribute])
        let appFocusedWindow = attributes.focusedWindow
        let appFocusedWid = try appFocusedWindow?.cgWindowId()
        let appMainWindow = attributes.mainWindow
        let appMainWid = try appMainWindow?.cgWindowId()
        if type == kAXFocusedWindowChangedNotification || type == kAXMainWindowChangedNotification {
            DispatchQueue.main.async {
                guard let app = Applications.findOrCreate(pid, false) else { return }
                Logger.info { "\(type) app:\(app.debugId)" }
                applicationFocusedOrMainWindowChanged(app, pid, type, appFocusedWindow, appFocusedWid, appMainWindow, appMainWid)
            }
            return
        }
        DispatchQueue.main.async {
            Applications.appListUpdateThrottler.throttleOrProceed(key: "\(pid)") {
                guard let app = Applications.findOrCreate(pid, false) else { return }
                Logger.info { "\(type) app:\(app.debugId)" }
                if type == kAXApplicationActivatedNotification {
                    applicationActivated(app, pid, type, appFocusedWindow, appFocusedWid)
                }
            }
        }
    }

    private static func applicationActivated(_ app: Application, _ pid: pid_t, _ type: String, _ appFocusedWindow: AXUIElement?, _ wid: CGWindowID?) {
        Diagnostics.log("AXEVENT", "applicationActivated pid=\(pid) app=\(app.bundleIdentifier ?? "?") guardActive=\(CFAbsoluteTimeGetCurrent() < Windows.altTabFocusTargetUntil) target=\(Windows.altTabFocusTarget?.debugId ?? "nil")")
        diagnoseCrossProcessActivation(activatedApp: app, activatedPid: pid)
        if Windows.shouldSuppressApplicationActivation(for: app) { return }
        Applications.frontmostPid = pid
        if app.hasBeenActiveOnce != true {
            app.hasBeenActiveOnce = true
        }
        if let appFocusedWindow, let wid {
            // if there is a focusedWindow, we reuse existing code to process it as if it was a kAXFocusedWindowChangedNotification
            AXCallScheduler.shared.schedule(key: "wid-\(wid)", context: "\(type) \(app.debugId))", pid: pid) {
                try handleEventWindow(kAXFocusedWindowChangedNotification, wid, pid, appFocusedWindow)
            }
        } else {
            App.checkIfShortcutsShouldBeDisabled(nil, app)
            if let windowless = (Windows.list.first { $0.isWindowlessApp && $0.application.pid == pid }) {
                // same suppression as focusedWindowChanged: during an
                // AltTab-initiated Parallels transition, don't let a
                // coincidental windowless app activation promote its
                // window into position 0 on top of our target.
                if Windows.shouldSuppressFocusOrderUpdate(for: windowless) { return }
                if let windows = Windows.updateLastFocusOrder(windowless) {
                    App.refreshOpenUiAfterExternalEvent(windows)
                }
            }
        }
    }

    /// Owners of transient overlay windows whose pid disappears milliseconds
    /// after the click. Their activations look like misroutes but are just
    /// the underlying app re-foregrounding after the overlay dismisses.
    private static let transientClickOwners: Set<String> = ["Screenshot", "screencaptureui"]

    /// Detect Parallels Coherence cross-process divergence: AltTab targeted one
    /// Parallels Windows-app proxy pid, but a *different* Parallels proxy pid
    /// was activated. Symptom: window appears front but Parallels routes
    /// keys/clicks/repaints to the wrong Windows app — looks like a render hang.
    /// For Coherence→Coherence click-misroutes, actively restore the clicked
    /// window's pid to frontmost so the user's input lands on the right app.
    private static func diagnoseCrossProcessActivation(activatedApp: Application, activatedPid: pid_t) {
        guard activatedApp.isParallelsCoherence else { return }
        if let target = Windows.altTabFocusTarget,
           target.application.isParallelsCoherence,
           target.application.pid != activatedPid {
            Diagnostics.log("XPROC", "Parallels divergence: activated pid=\(activatedPid) (\(activatedApp.bundleIdentifier?.suffix(40) ?? "?")) but altTab target pid=\(target.application.pid) (\(target.debugId)) — input may route wrong")
        }
        let dt = CFAbsoluteTimeGetCurrent() - Windows.lastMouseClickTime
        guard dt < 1.0, Windows.lastMouseClickPid != 0, Windows.lastMouseClickPid != activatedPid else { return }
        guard !transientClickOwners.contains(Windows.lastMouseClickOwner) else { return }
        Diagnostics.log("XPROC", "click-misroute (+\(Int(dt*1000))ms): clicked wid=\(Windows.lastMouseClickWid) pid=\(Windows.lastMouseClickPid) (\(Windows.lastMouseClickOwner)) but activated pid=\(activatedPid) (\(activatedApp.bundleIdentifier?.suffix(40) ?? "?"))")
        guard let clickedWindow = Windows.list.first(where: { $0.cgWindowId == Windows.lastMouseClickWid }),
              clickedWindow.application.isParallelsCoherence else { return }
        Windows.restoreFrontmostToTarget(targetWid: Windows.lastMouseClickWid, targetPid: Windows.lastMouseClickPid, frontPid: activatedPid, source: "XPROC", bypassThrottle: true)
    }

    private static func applicationFocusedOrMainWindowChanged(_ app: Application, _ pid: pid_t, _ type: String, _ appFocusedWindow: AXUIElement?, _ appFocusedWid: CGWindowID?, _ appMainWindow: AXUIElement?, _ appMainWid: CGWindowID?) {
        guard app.runningApplication.isActive else { return }
        Applications.frontmostPid = pid
        let axWindow = appFocusedWindow ?? appMainWindow
        let wid = appFocusedWid ?? appMainWid
        guard let axWindow, let wid else {
            app.focusedWindow = nil
            return
        }
        AXCallScheduler.shared.schedule(key: "wid-\(wid)", context: "\(type) \(app.debugId))", pid: pid) {
            try handleEventWindow(kAXFocusedWindowChangedNotification, wid, pid, axWindow)
        }
    }

    private static func applicationHiddenOrShown(_ app: Application, _ pid: pid_t, _ type: String) {
        app.isHidden = type == kAXApplicationHiddenNotification
        let windows = Windows.list.filter {
            // for AXUIElement of apps, CFEqual or == don't work; looks like a Cocoa bug
            return $0.application.pid == pid
        }
        // if we process the "shown" event too fast, UI may not be ready; we add a delay to work around this
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(200)) {
            App.refreshOpenUiAfterExternalEvent(windows)
        }
    }

    static func handleEventWindow(_ type: String, _ wid: CGWindowID, _ pid: pid_t, _ element: AXUIElement) throws {
        let level = wid.level()
        // if we query .children on ourselves, AppKit calls layout directly from our thread instead of IPC; we avoid this
        let isSelf = pid == ProcessInfo.processInfo.processIdentifier
        let keys = [kAXTitleAttribute, kAXSubroleAttribute, kAXRoleAttribute, kAXSizeAttribute, kAXPositionAttribute, kAXFullscreenAttribute, kAXMinimizedAttribute] + (isSelf ? [] : [kAXChildrenAttribute])
        let a = try element.attributes(keys)
        let tabSiblingTitles = isSelf ? nil : TabGroup.extractTabTitles(a.children)
        DispatchQueue.main.async {
            Applications.windowListUpdateThrottler.throttleOrProceed(key: "\(wid)") {
                guard let app = Applications.findOrCreate(pid, false) else { return }
                Logger.info { "\(type) wid:\(wid) app:\(app.debugId)" }
                let findOrCreate = Windows.findOrCreate(element, wid, app, level, a.title, a.subrole, a.role, a.size, a.position, a.isFullscreen, a.isMinimized)
                guard let window = findOrCreate.0 else {
                    // we don't know this window, but it got focused, so let's update app.focusedWindow with nil
                    if type == kAXFocusedWindowChangedNotification && a.role != kAXSheetRole {
                        app.focusedWindow = nil
                    }
                    return
                }
                Logger.debug { "\(type) win:\(window.debugId)" }
                var tabStateChanged = false
                if tabSiblingTitles != nil || window.tabbedSiblingWids != nil {
                    tabStateChanged = TabGroup.updateState(window, tabSiblingTitles)
                }
                if findOrCreate.1 || (tabStateChanged && App.appIsBeingUsed) {
                    App.refreshOpenUiAfterExternalEvent([window])
                }
                if type == kAXMainWindowChangedNotification || type == kAXFocusedWindowChangedNotification {
                    focusedWindowChanged(window)
                } else if type == kAXWindowResizedNotification || type == kAXWindowMovedNotification {
                    windowResizedOrMoved(window)
                } else if !findOrCreate.1 {
                    App.refreshOpenUiAfterExternalEvent([window])
                }
            }
        }
    }

    private static func windowDestroyed(_ windowAxUiElement: AXUIElement, _ pid: pid_t, _ wid: CGWindowID) {
        if let window = (Windows.list.first { $0.isEqualRobust(windowAxUiElement, wid) }) {
            let wasFrontmost = window.application.runningApplication.isActive
            let wasParallels = window.application.isParallelsCoherence
            Diagnostics.log("AXEVENT", "windowDestroyed wid=\(wid) \(window.debugId ?? "?") wasFront=\(wasFrontmost) par=\(wasParallels)")
            Windows.removeWindows([window], true)
            // When a Parallels window is closed while frontmost, macOS raises
            // the next window from the same process — which may not match our
            // recency order. Restore the correct z-order from our recency list.
            if wasFrontmost && wasParallels {
                Windows.restoreZOrderFromRecency()
            }
        }
    }

    private static func focusedWindowChanged(_ window: Window) {
        // photoshop will focus a window *after* you focus another app
        // we check that a focused window happens within an active app
        guard window.application.runningApplication.isActive else { return }
        // if the window is shown by alt-tab, we mark it as focused for this app
        // this avoids issues with dialogs, quicklook, etc (see scenarios from #1044 and #2003)
        window.application.focusedWindow = window
        App.checkIfShortcutsShouldBeDisabled(window, nil)
        // During an AltTab-initiated Parallels focus transition, Cocoa
        // often fires a brief spurious focus-changed for the target app's
        // PREVIOUSLY-key window before settling on the real target. Skip
        // `updateLastFocusOrder` for those so the recency list doesn't
        // get a stale window promoted to position 0.
        if Windows.shouldSuppressFocusOrderUpdate(for: window) { return }
        if let windows = Windows.updateLastFocusOrder(window) {
            App.refreshOpenUiAfterExternalEvent(windows)
        }
    }

    private static func windowResizedOrMoved(_ window: Window) {
        window.updateSpacesAndScreen()
        App.refreshOpenUiAfterExternalEvent([window])
    }
}
