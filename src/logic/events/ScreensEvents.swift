import Cocoa

class ScreensEvents {
    private static let throttler = Throttler(delayInMs: 200)
    private static var refreshGeneration = 0
    private static var lastScreenSnapshot = screenSnapshot()

    static func observe() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleEvent), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private static func handleEvent(_ notification: Notification) {
        // screen notifications often arrive in groups (e.g. 2 in a row in a short time)
        throttler.throttleOrProceed {
            Logger.debug { notification.name.rawValue }
            let before = lastScreenSnapshot
            Spaces.refresh()
            Screens.refresh()
            let after = screenSnapshot()
            Diagnostics.log("REFRESH", "screen parameters changed before=[\(before)] after=[\(after)] panelOpen=\(App.appIsBeingUsed)")
            lastScreenSnapshot = after
            Windows.requestZOrderReview(reason: "screen-parameters-changed", fullDelayMs: 700)
            // a screen added or removed, or screen resolution change can mess up layout; we reset components
            App.resetPreferencesDependentComponents()
            prepareThumbnailsForDisplayChange()
            App.refreshOpenUiAfterExternalEvent([])
            scheduleThumbnailRefreshes()
            Logger.info { "screens:\(NSScreen.screens.map { ($0.cachedUuid() ?? "nil" as CFString, $0.frame) })" }
            Logger.info { "currentSpace:\(Spaces.currentSpaceIndex) (id:\(Spaces.currentSpaceId)) spaces:\(Spaces.screenSpacesMap)" }
        }
    }

    private static func prepareThumbnailsForDisplayChange() {
        refreshGeneration += 1
        // Don't blank thumbnails on screen change. Stale is much better
        // than empty: the user might never alt-tab again before the
        // BackgroundThumbnailRefresher catches up (~10s), and screen
        // reconfigs already saturate WindowServer — a simultaneous
        // panic-rerender of every thumbnail makes it worse.
        Diagnostics.log("CAPTURE", "screen change: preserving current thumbnails (panel=\(App.appIsBeingUsed))")
        if #available(macOS 14.0, *) {
            // Only the SCWindow lookup list needs invalidating (cheap to
            // rebuild and necessary since window IDs/geometry change).
            WindowCaptureScreenshots.invalidateCache()
        }
    }

    private static func screenSnapshot() -> String {
        NSScreen.screens.map { screen in
            let uuid = screen.cachedUuid() as String? ?? "nil"
            let frame = screen.frame
            return "\(uuid)@\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height)) scale=\(screen.backingScaleFactor)"
        }.joined(separator: " | ")
    }

    private static func scheduleThumbnailRefreshes() {
        // Single ~1s reissue handles the immediate post-reconfig
        // re-screenshot. Anything still stale after that is picked up by
        // BackgroundThumbnailRefresher's natural 5/10s cadence — no need
        // for the old [700, 2200, 5000] shotgun.
        let generation = refreshGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1000)) {
            guard generation == refreshGeneration else { return }
            App.refreshOpenUiAfterExternalEvent(Windows.list, source: .screenParametersChanged)
        }
    }
}
