import Cocoa

class RunningApplicationsEvents {
    private static var appsObserver: NSKeyValueObservation!

    static func observe() {
        // we can't observe NSWorkspace.didLaunchApplicationNotification or NSWorkspace.didTerminateApplicationNotification
        // these only trigger for some apps, mostly GUI app. We need to track all processes as any could spawn a window
        appsObserver = NSWorkspace.shared.observe(\.runningApplications, options: [.old, .new], changeHandler: { (_, change) in handleEvent(change) })
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleWorkspaceAppEvent), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleWorkspaceAppEvent), name: NSWorkspace.didHideApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(handleWorkspaceAppEvent), name: NSWorkspace.didUnhideApplicationNotification, object: nil)
    }

    private static func handleEvent(_ change: NSKeyValueObservedChange<[NSRunningApplication]>) {
        let launched = change.newValue
        let quit = change.oldValue
        if let launched {
            Logger.debug { "launched:\(launched.map { $0.debugId() })" }
            Applications.addRunningApplications(launched, true)
            Windows.requestZOrderReview(reason: "app-launched", fullDelayMs: 700)
        }
        if let quit {
            Logger.debug { "quit:\(quit.map { $0.debugId() })" }
            Applications.removeRunningApplications(quit)
            Windows.requestZOrderReview(reason: "app-quit", fullDelayMs: 700)
        }
    }

    @objc private static func handleWorkspaceAppEvent(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let pid = app?.processIdentifier ?? 0
        if notification.name == NSWorkspace.didActivateApplicationNotification,
           let trackedApp = Applications.findOrCreate(pid, false) {
            if Windows.releaseZOrderEnforcementForRecentExternalActivation(pid: trackedApp.pid, label: notification.name.rawValue) {
                Windows.requestZOrderTopReview(reason: notification.name.rawValue, wid: 0)
                Logger.debug { "\(notification.name.rawValue) pid:\(pid) app:\(app?.debugId() ?? "?") released stale z-enforcement" }
                return
            }
            if Windows.shouldCounterPostAltTabParallelsActivation(for: trackedApp, wid: nil, reason: notification.name.rawValue) {
                Logger.debug { "\(notification.name.rawValue) pid:\(pid) app:\(app?.debugId() ?? "?") suppressed" }
                return
            }
        }
        Windows.requestZOrderTopReview(reason: notification.name.rawValue, wid: 0)
        Logger.debug { "\(notification.name.rawValue) pid:\(pid) app:\(app?.debugId() ?? "?")" }
    }
}
