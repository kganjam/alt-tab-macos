import Cocoa

class ScreensEvents {
    private static let throttler = Throttler(delayInMs: 200)
    private static var refreshGeneration = 0

    static func observe() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleEvent), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private static func handleEvent(_ notification: Notification) {
        // screen notifications often arrive in groups (e.g. 2 in a row in a short time)
        throttler.throttleOrProceed {
            Logger.debug { notification.name.rawValue }
            Spaces.refresh()
            Screens.refresh()
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
        Windows.invalidateThumbnails()
        if #available(macOS 14.0, *) {
            WindowCaptureScreenshots.invalidateCache()
        }
    }

    private static func scheduleThumbnailRefreshes() {
        let generation = refreshGeneration
        [700, 2200, 5000].forEach { delayMs in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
                guard generation == refreshGeneration else { return }
                App.refreshOpenUiAfterExternalEvent(Windows.list, source: .screenParametersChanged)
            }
        }
    }
}
