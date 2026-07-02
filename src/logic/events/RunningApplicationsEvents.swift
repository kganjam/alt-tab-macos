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
        let launched = launchedApplications(change)
        let quit = quitApplications(change)
        if !launched.isEmpty {
            Logger.debug { "launched:\(launched.map { $0.debugId() })" }
            Applications.addRunningApplications(launched, true)
            requestLifecycleZOrderReview(reason: "app-launched", apps: launched)
        }
        if !quit.isEmpty {
            Logger.debug { "quit:\(quit.map { $0.debugId() })" }
            Applications.removeRunningApplications(quit)
            requestLifecycleZOrderReview(reason: "app-quit", apps: quit)
        }
    }

    private static func launchedApplications(_ change: NSKeyValueObservedChange<[NSRunningApplication]>) -> [NSRunningApplication] {
        switch change.kind {
        case .insertion:
            return indexedApplications(change.newValue, change.indexes) ?? diffApplications(change).launched
        case .setting, .replacement:
            return diffApplications(change).launched
        default:
            return []
        }
    }

    private static func quitApplications(_ change: NSKeyValueObservedChange<[NSRunningApplication]>) -> [NSRunningApplication] {
        switch change.kind {
        case .removal:
            return indexedApplications(change.oldValue, change.indexes) ?? diffApplications(change).quit
        case .setting, .replacement:
            return diffApplications(change).quit
        default:
            return []
        }
    }

    private static func indexedApplications(_ apps: [NSRunningApplication]?, _ indexes: IndexSet?) -> [NSRunningApplication]? {
        guard let apps, let indexes else { return nil }
        var indexed = [NSRunningApplication]()
        for index in indexes {
            guard apps.indices.contains(index) else { return nil }
            indexed.append(apps[index])
        }
        return indexed
    }

    private static func diffApplications(_ change: NSKeyValueObservedChange<[NSRunningApplication]>) -> (launched: [NSRunningApplication], quit: [NSRunningApplication]) {
        guard let new = change.newValue, let old = change.oldValue else { return (change.newValue ?? [], change.oldValue ?? []) }
        let newPids = Set(new.map { $0.processIdentifier })
        let oldPids = Set(old.map { $0.processIdentifier })
        return (new.filter { !oldPids.contains($0.processIdentifier) }, old.filter { !newPids.contains($0.processIdentifier) })
    }

    private static func requestLifecycleZOrderReview(reason: String, apps: [NSRunningApplication]) {
        if apps.contains(where: { $0.activationPolicy == .regular }) {
            Windows.requestZOrderReview(reason: reason, fullDelayMs: 700)
        } else {
            Windows.requestZOrderTopReview(reason: reason)
        }
    }

    @objc private static func handleWorkspaceAppEvent(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let pid = app?.processIdentifier ?? 0
        let name = notification.name.rawValue
        // Record which app activated and what AltTab decided. The generic
        // "z-order top review reason=NSWorkspace…" REFRESH line does NOT carry
        // the activating pid/app, so a Parallels app (e.g. Excel launched from
        // the dock) being activated — and any COUNTER that re-raises the prior
        // AltTab target over it — was previously only visible via Logger.debug
        // (off at the default level). Log it at info so the activation→decision
        // chain is greppable without enabling trace.
        if notification.name == NSWorkspace.didActivateApplicationNotification,
           let trackedApp = Applications.findOrCreate(pid, false) {
            let coherence = trackedApp.isParallelsCoherence
            if Windows.releaseZOrderEnforcementForExternalForegroundOwner(pid: trackedApp.pid, label: name) {
                Windows.requestZOrderTopReview(reason: name, wid: 0)
                Diagnostics.log("ACTIVATE", "\(name) pid=\(pid) app=\(trackedApp.debugId) coherence=\(coherence) → released stale z-enforcement")
                Logger.debug { "\(name) pid:\(pid) app:\(app?.debugId() ?? "?") released stale z-enforcement" }
                return
            }
            if Windows.shouldCounterPostAltTabParallelsActivation(for: trackedApp, wid: nil, reason: name) {
                Diagnostics.log("ACTIVATE", "\(name) pid=\(pid) app=\(trackedApp.debugId) coherence=\(coherence) → COUNTERED: re-raising prior AltTab target over it")
                Logger.debug { "\(name) pid:\(pid) app:\(app?.debugId() ?? "?") suppressed" }
                return
            }
            Diagnostics.log("ACTIVATE", "\(name) pid=\(pid) app=\(trackedApp.debugId) coherence=\(coherence) → z-order top review")
        }
        Windows.requestZOrderTopReview(reason: name, wid: 0)
        Logger.debug { "\(name) pid:\(pid) app:\(app?.debugId() ?? "?")" }
    }
}
