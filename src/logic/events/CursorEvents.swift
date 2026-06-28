import Cocoa
import Carbon.HIToolbox.Events

class CursorEvents {
    private static var eventTap: CFMachPort!        // main-runloop tap (mouseMoved + right/other; + left when off-main disabled)
    private static var clickTap: CFMachPort!         // dedicated-thread tap (left clicks only, off-main mode)
    private static var clickTapThread: Thread?
    private static var clickTapUsed = false
    private static var shouldBeEnabled: Bool!
    private static var mouseDownTarget: AnyObject?         // MAIN-thread only (set/read in click actions)
    private static var mouseDownWindowId: CGWindowID = 0   // cgWindowId of the tile the user pressed on (0 = none)
    private static var mouseDownInsideSearchField = false  // MAIN-tap path only
    private static var clickTapDownInSearchField = false   // click-tap THREAD only
    private static var outsideMouseDownPassedThroughButton: String?
    static var deadZoneInitialPosition: CGPoint?
    static var isAllowedToMouseHover = true
    private static var hoverPollTimer: Timer?
    private static var lastHoverPollLocation: CGPoint?

    /// Run the LEFT-click tap on a dedicated thread instead of the main runloop.
    /// The main-runloop tap is disabled by macOS (and drops the event) whenever
    /// the main thread stalls past the tap timeout — which is why thumbnail clicks
    /// were intermittently lost under load. A dedicated thread services the tap's
    /// mach port promptly regardless of main-thread load; the click is absorbed
    /// synchronously from a cached geometry snapshot and the focus work is
    /// dispatched to main (delayed under load, never dropped). Default on; set
    /// `offMainClickTapEnabled -bool false` + relaunch to fall back to the
    /// original single main-thread tap.
    private static var offMainClickTapEnabled: Bool {
        UserDefaults.standard.object(forKey: "offMainClickTapEnabled") as? Bool ?? true
    }

    // MARK: - Click-tap geometry snapshot (written on main, read on the click-tap thread)

    private struct ClickTapGeometry {
        var searchFieldRectCocoaGlobal: CGRect?   // nil when the search field is hidden
        var flipHeight: CGFloat = 0               // main-screen height, to map CG-global → Cocoa-global
        var hasMarkedText = false                 // IME composition in the search field
    }
    private static var clickGeo = ClickTapGeometry()
    private static let clickGeoLock = NSLock()

    /// Recompute the click-tap geometry on the main thread. Called frequently
    /// (every hover-poll tick while the panel is open, ≤16ms stale) so the
    /// click-tap thread always has fresh search-field/IME state without hunting
    /// for every layout/search hook.
    static func refreshClickTapGeometry() {
        guard Thread.isMainThread else { return }
        var g = ClickTapGeometry()
        g.flipHeight = NSScreen.main?.frame.height ?? 0
        g.hasMarkedText = TilesView.hasMarkedText()
        let sf = TilesView.searchField
        if !sf.isHidden, let win = sf.window {
            g.searchFieldRectCocoaGlobal = win.convertToScreen(sf.convert(sf.bounds, to: nil))
        }
        clickGeoLock.lock(); clickGeo = g; clickGeoLock.unlock()
    }

    private static func readClickGeo() -> ClickTapGeometry {
        clickGeoLock.lock(); defer { clickGeoLock.unlock() }
        return clickGeo
    }

    static func observe() {
        observe_()
    }

    static func toggle(_ enabled: Bool) {
        guard enabled != shouldBeEnabled else { return }
        shouldBeEnabled = enabled
        Diagnostics.log("CTAP", "toggle enabled=\(enabled)")
        if !enabled {
            deadZoneInitialPosition = nil
        }
        if enabled { refreshClickTapGeometry() }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: enabled)
        }
        if let clickTap {
            CGEvent.tapEnable(tap: clickTap, enable: enabled)
        }
        toggleHoverPoll(enabled)
    }

    /// Poll the live cursor position while the panel is open and re-run hover
    /// detection, independent of the mouseMoved event stream.
    ///
    /// The mouseMoved tap runs on the main runloop; when the main thread is busy
    /// (e.g. WindowServer under load) macOS coalesces and drops mouseMoved
    /// events — including, on a fast flick, the final event at the resting
    /// position — so `updateHover` never runs for the tile actually under the
    /// cursor and the highlight sticks on the previous tile. This poll reads the
    /// cursor directly (`CGEvent(source:)`, same Quartz coordinate space as the
    /// tap, so the dead-zone arming stays consistent), so a fast move always
    /// resolves to the correct tile. `updateHover` early-returns when the target
    /// is unchanged, so an idle tick is just a cheap rect test.
    private static func toggleHoverPoll(_ enabled: Bool) {
        hoverPollTimer?.invalidate()
        hoverPollTimer = nil
        lastHoverPollLocation = nil
        guard enabled else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            // Keep the click-tap thread's geometry fresh (search field / IME).
            refreshClickTapGeometry()
            let location = CGEvent(source: nil)?.location ?? .zero
            guard isAllowedToReactToPointerMovement(location) else { return }
            let previous = lastHoverPollLocation
            lastHoverPollLocation = location
            // Velocity gate: while the cursor is flicking fast across the grid,
            // skip hover updates so the highlight doesn't chase through — and pay
            // the per-tile scroll/preview/window-control cost for — every tile the
            // cursor passes over. Human pointing decelerates onto the target, so as
            // the flick lands its per-tick travel drops below ~one tile and the
            // next tick resolves the tile actually under the cursor. The threshold
            // scales with tile width (with a floor) so it gates genuine flicks, not
            // deliberate slow hover-scanning where every tile should highlight.
            if let previous {
                let movedThisTick = hypot(location.x - previous.x, location.y - previous.y)
                let tileWidth = TilesView.recycledViews.first(where: { $0.frame.width > 0 })?.frame.width ?? 160
                if movedThisTick > max(40, tileWidth * 0.8) { return }
            }
            TilesView.thumbnailOverView.updateHover()
        }
        timer.tolerance = 1.0 / 120.0
        RunLoop.main.add(timer, forMode: .common)
        hoverPollTimer = timer
    }

    static func reEnableTapIfNeeded() {
        if let eventTap, shouldBeEnabled, !CGEvent.tapIsEnabled(tap: eventTap) {
            CGEvent.tapEnable(tap: eventTap, enable: true)
            Logger.warning { "" }
        }
        if let clickTap, shouldBeEnabled, !CGEvent.tapIsEnabled(tap: clickTap) {
            CGEvent.tapEnable(tap: clickTap, enable: true)
        }
    }

    private static func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
    }

    private static func observe_() {
        let leftTypes: [CGEventType] = [.leftMouseDown, .leftMouseUp]
        let allTypes: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved]
        // Try to stand up the dedicated-thread LEFT-click tap first; only then do
        // we know whether the main tap should exclude left clicks.
        clickTapUsed = false
        if offMainClickTapEnabled {
            clickTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask(leftTypes), callback: handleClickTapEvent, userInfo: nil)
            clickTapUsed = (clickTap != nil)
        }
        let mainTypes = clickTapUsed ? allTypes.filter { !leftTypes.contains($0) } : allTypes
        // CGEvent.tapCreate returns nil if ensureAccessibilityCheckboxIsChecked() didn't pass
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask(mainTypes), callback: handleEvent, userInfo: nil)
        guard let eventTap else {
            App.restart()
            return
        }
        toggle(false)
        let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
        // The main tap runs on the main runloop: it only does mouseMoved (hover/
        // dead-zone) and right/other clicks, all of which must touch NSEvent/UI on
        // main. LEFT clicks go to the dedicated-thread clickTap (see below) so they
        // survive main-thread stalls.
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        if clickTapUsed {
            startClickTapThread()
            Diagnostics.log("SESSION", "left-click tap on DEDICATED THREAD (off-main); main tap handles moved/right/other")
        } else {
            Diagnostics.log("SESSION", "single MAIN-THREAD tap (off-main left-click tap disabled or unavailable)")
        }
    }

    /// Dedicated thread whose runloop services the LEFT-click tap so its mach
    /// port is processed promptly even when the main thread is stalled.
    private static func startClickTapThread() {
        let thread = Thread {
            guard let clickTap else { return }
            let source = CFMachPortCreateRunLoopSource(nil, clickTap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "com.lwouis.alt-tab-macos.clickTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        clickTapThread = thread
    }

    // MARK: - Main-runloop tap (mouseMoved + right/other; + left when off-main disabled)

    private static let handleEvent: CGEventTapCallBack = { _, type, cgEvent, _ in
        switch type {
            case .leftMouseDown: return handleLeftMouseDown(cgEvent)
            case .leftMouseUp: return handleLeftMouseUp(cgEvent)
            case .rightMouseDown: return handleRightMouseDown(cgEvent)
            case .rightMouseUp: return handleRightMouseUp(cgEvent)
            case .otherMouseDown: return handleOtherMouseDown(cgEvent)
            case .otherMouseUp: return handleOtherMouseUp(cgEvent)
            case .mouseMoved: return handleMouseMoved(cgEvent)
            case .tapDisabledByUserInput, .tapDisabledByTimeout:
                // Only surface disables that happen while we WANT the tap on
                // (panel open): those drop real input. The disable that fires when
                // we intentionally turn the tap off on panel-close (shouldBeEnabled
                // == false) is benign and would just be noise.
                if shouldBeEnabled == true {
                    Diagnostics.log("CTAPDISABLE", "main tap disabled by \(type == .tapDisabledByTimeout ? "TIMEOUT (main-thread stall → moved/right/other dropped)" : "userInput") while enabled; re-enabling")
                    CGEvent.tapEnable(tap: eventTap!, enable: true)
                }
                return Unmanaged.passUnretained(cgEvent)
            default: return Unmanaged.passUnretained(cgEvent)
        }
    }

    // MARK: - Dedicated-thread LEFT-click tap

    private static let handleClickTapEvent: CGEventTapCallBack = { _, type, cgEvent, _ in
        switch type {
            case .leftMouseDown: return clickTapLeftDown(cgEvent)
            case .leftMouseUp: return clickTapLeftUp(cgEvent)
            case .tapDisabledByUserInput, .tapDisabledByTimeout:
                if shouldBeEnabled == true {
                    // Should be rare now: this tap is on its own thread, not blocked
                    // by main-thread stalls.
                    Diagnostics.log("CTAPDISABLE", "CLICK tap (dedicated thread) disabled by \(type == .tapDisabledByTimeout ? "TIMEOUT" : "userInput"); re-enabling")
                    CGEvent.tapEnable(tap: clickTap!, enable: true)
                }
                return Unmanaged.passUnretained(cgEvent)
            default: return Unmanaged.passUnretained(cgEvent)
        }
    }

    /// Runs on the click-tap thread. Decides absorb-vs-pass synchronously from the
    /// cached geometry, then dispatches the real (main-thread) focus work with the
    /// EVENT's own location so a delayed action still targets where the user
    /// actually clicked.
    private static func clickTapLeftDown(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        let loc = cgEvent.location
        let geo = readClickGeo()
        if geo.hasMarkedText || ContextMenuEvents.isMenuOpen {
            return Unmanaged.passUnretained(cgEvent)
        }
        if let sf = geo.searchFieldRectCocoaGlobal,
           sf.contains(CGPoint(x: loc.x, y: geo.flipHeight - loc.y)) {
            clickTapDownInSearchField = true
            return Unmanaged.passUnretained(cgEvent)
        }
        clickTapDownInSearchField = false
        let enqueuedAt = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async { performLeftDownAction(enqueuedAt: enqueuedAt) }
        return nil
    }

    private static func clickTapLeftUp(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        let loc = cgEvent.location
        let geo = readClickGeo()
        if geo.hasMarkedText || ContextMenuEvents.isMenuOpen {
            return Unmanaged.passUnretained(cgEvent)
        }
        let inSearch = geo.searchFieldRectCocoaGlobal.map { $0.contains(CGPoint(x: loc.x, y: geo.flipHeight - loc.y)) } ?? false
        if clickTapDownInSearchField || inSearch {
            clickTapDownInSearchField = false
            return Unmanaged.passUnretained(cgEvent)
        }
        let enqueuedAt = CFAbsoluteTimeGetCurrent()
        Diagnostics.log("CLICKTAP", "recv left-up → absorb + defer focus")
        DispatchQueue.main.async { performLeftUpAction(enqueuedAt: enqueuedAt) }
        return nil
    }

    private static func performLeftDownAction(enqueuedAt: CFAbsoluteTime) {
        guard App.appIsBeingUsed else { return }  // panel closed before this ran — stale
        outsideMouseDownPassedThroughButton = nil
        mouseDownTarget = nil
        // Use the LIVE pointer position (same as the original synchronous handlers)
        // rather than re-deriving it from the event's global location — that
        // conversion was unreliable and silently put the point outside the panel.
        // For a normal click the action runs within a frame, so live ≈ click.
        guard isPointerInsideUi() else {
            App.hideUi()
            return
        }
        mouseDownTarget = (findButtonUnderPointer() ?? findTileViewUnderPointer()) as AnyObject?
        mouseDownWindowId = (mouseDownTarget as? TileView)?.window_?.cgWindowId ?? 0
    }

    private static func performLeftUpAction(enqueuedAt: CFAbsoluteTime) {
        // The click was absorbed instantly on the click-tap thread; this focus
        // work runs on main. Under a main-thread stall it can run later — the click
        // isn't dropped, but the window comes forward late, which feels like a miss.
        // `lag` quantifies that delay; a large lag means the cure is reducing
        // main-thread stalls, not the click path.
        let lagMs = (CFAbsoluteTimeGetCurrent() - enqueuedAt) * 1000
        if lagMs > 250 {
            Diagnostics.log("CLICKLAG", "left-click focus ran \(Int(lagMs))ms after the click (main-thread stall delayed it; click captured)")
        }
        guard App.appIsBeingUsed else {
            Diagnostics.log("CLICKLAG", "left-click NOT applied: panel closed before the focus action ran (lag=\(Int(lagMs))ms)")
            return
        }
        guard isPointerInsideUi() else {
            if mouseDownTarget == nil { App.hideUi() }
            mouseDownTarget = nil
            Diagnostics.log("CLICKMISS", "left-click release not over the panel at action time (lag=\(Int(lagMs))ms) — cursor moved off / panel relaid; not applied")
            return
        }
        let downTarget = mouseDownTarget
        let downWid = mouseDownWindowId
        mouseDownTarget = nil
        mouseDownWindowId = 0
        resolveLeftClickFocus(downTarget: downTarget, downWid: downWid, lagMs: lagMs)
    }

    /// Decide what a completed left click focuses. Focuses the WINDOW the user
    /// PRESSED on — the thumbnail they saw and aimed at — located via whatever tile
    /// currently shows it, so it's robust to the grid relaying out / tiles being
    /// recycled between press and release (the bug where a stationary click focused
    /// a different window than the one pressed). Falls back to the release tile only
    /// when there was no press target (a dropped mousedown event). Buttons keep
    /// strict press+release semantics so a traffic-light action never misfires.
    private static func resolveLeftClickFocus(downTarget: AnyObject?, downWid: CGWindowID, lagMs: Double) {
        if let button = findButtonUnderPointer(), button === downTarget {
            button.onClick()
            return
        }
        if downWid != 0, let tile = TilesView.recycledViews.first(where: { $0.window_?.cgWindowId == downWid }) {
            Diagnostics.log("CLICKTAP", "FOCUS press-target wid#\(downWid) '\(tile.window_?.title ?? "?")' (lag=\(Int(lagMs))ms)")
            tile.mouseUpCallback()
            return
        }
        if let upTile = findTileViewUnderPointer() {
            Diagnostics.log("CLICKMISS", "recovered: no press target (down=\(describeTarget(downTarget)) wid#\(downWid)) → release tile#\(upTile.window_?.cgWindowId ?? 0) (lag=\(Int(lagMs))ms)")
            upTile.mouseUpCallback()
            return
        }
        Diagnostics.log("CLICKMISS", "left click did nothing: downWid#\(downWid) upTile=nil (lag=\(Int(lagMs))ms)")
    }

    /// Logs the click-tap decision so absorbed events become visible.
    /// The existing global NSEvent monitor in App.swift only sees clicks
    /// that were NOT absorbed by this tap — so without this, an absorbed
    /// click is invisible everywhere.
    private static func logTapDecision(_ btn: String, _ action: String, _ cgEvent: CGEvent, absorbed: Bool, reason: String = "") {
        let p = cgEvent.location
        let suffix = reason.isEmpty ? "" : " (\(reason))"
        Diagnostics.log("CTAP", "\(btn) \(action) at (\(Int(p.x)),\(Int(p.y))) absorbed=\(absorbed)\(suffix)")
    }

    private static func handleLeftMouseDown(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        outsideMouseDownPassedThroughButton = nil
        if TilesView.hasMarkedText() || ContextMenuEvents.isMenuOpen {
            logTapDecision("left", "down", cgEvent, absorbed: false, reason: "markedText/menuOpen")
            return Unmanaged.passUnretained(cgEvent)
        }
        if isPointerInsideSearchField() {
            mouseDownInsideSearchField = true
            logTapDecision("left", "down", cgEvent, absorbed: false, reason: "searchField")
            return Unmanaged.passUnretained(cgEvent)
        }
        mouseDownInsideSearchField = false
        guard isPointerInsideUi() else {
            return handleOutsideUiMouseDown("left", cgEvent)
        }
        mouseDownTarget = (findButtonUnderPointer() ?? findTileViewUnderPointer()) as AnyObject?
        mouseDownWindowId = (mouseDownTarget as? TileView)?.window_?.cgWindowId ?? 0
        logTapDecision("left", "down", cgEvent, absorbed: true, reason: "insideUi")
        return nil
    }

    private static func handleLeftMouseUp(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if let pass = handleOutsideUiMouseUpIfNeeded("left", cgEvent) { return pass }
        if TilesView.hasMarkedText() || ContextMenuEvents.isMenuOpen {
            logTapDecision("left", "up", cgEvent, absorbed: false, reason: "markedText/menuOpen")
            return Unmanaged.passUnretained(cgEvent)
        }
        if mouseDownInsideSearchField || isPointerInsideSearchField() {
            mouseDownInsideSearchField = false
            logTapDecision("left", "up", cgEvent, absorbed: false, reason: "searchField")
            return Unmanaged.passUnretained(cgEvent)
        }
        guard isPointerInsideUi() else {
            if mouseDownTarget == nil { App.hideUi() }
            mouseDownTarget = nil
            logTapDecision("left", "up", cgEvent, absorbed: true, reason: "outsideUi→hideUi")
            return nil
        }
        let downTarget = mouseDownTarget
        let downWid = mouseDownWindowId
        mouseDownTarget = nil
        mouseDownWindowId = 0
        // Prefer the pressed window; fall back to the release tile only on a dropped
        // mousedown (see resolveLeftClickFocus).
        resolveLeftClickFocus(downTarget: downTarget, downWid: downWid, lagMs: 0)
        logTapDecision("left", "up", cgEvent, absorbed: true, reason: "resolved")
        return nil
    }

    private static func describeTarget(_ obj: AnyObject?) -> String {
        guard let obj else { return "nil" }
        if let tile = obj as? TileView { return "tile#\(tile.window_?.cgWindowId ?? 0)" }
        if let btn = obj as? TrafficLightButton { return "button:\(btn.type)" }
        return "other"
    }

    private static func handleRightMouseDown(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        outsideMouseDownPassedThroughButton = nil
        if ContextMenuEvents.isMenuOpen || isPointerInsideUi() {
            logTapDecision("right", "down", cgEvent, absorbed: false, reason: "menuOpen/insideUi")
            return Unmanaged.passUnretained(cgEvent)
        }
        return handleOutsideUiMouseDown("right", cgEvent)
    }

    private static func handleRightMouseUp(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if let pass = handleOutsideUiMouseUpIfNeeded("right", cgEvent) { return pass }
        if ContextMenuEvents.isMenuOpen || isPointerInsideUi() {
            logTapDecision("right", "up", cgEvent, absorbed: false, reason: "menuOpen/insideUi")
            return Unmanaged.passUnretained(cgEvent)
        }
        logTapDecision("right", "up", cgEvent, absorbed: true, reason: "outsideUi")
        return nil
    }

    private static func handleOtherMouseDown(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        outsideMouseDownPassedThroughButton = nil
        if ContextMenuEvents.isMenuOpen || isPointerInsideUi() {
            logTapDecision("other", "down", cgEvent, absorbed: false, reason: "menuOpen/insideUi")
            return Unmanaged.passUnretained(cgEvent)
        }
        return handleOutsideUiMouseDown("other", cgEvent)
    }

    private static func handleOtherMouseUp(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        if let pass = handleOutsideUiMouseUpIfNeeded("other", cgEvent) { return pass }
        if ContextMenuEvents.isMenuOpen {
            logTapDecision("other", "up", cgEvent, absorbed: false, reason: "menuOpen")
            return Unmanaged.passUnretained(cgEvent)
        }
        if isPointerInsideUi(),
           cgEvent.getIntegerValueField(.mouseEventButtonNumber) == 2,
           let target = findTileViewUnderPointer(),
           let window = target.window_ {
            window.isWindowlessApp ? window.application.quit() : window.close()
        }
        logTapDecision("other", "up", cgEvent, absorbed: true, reason: "")
        return nil
    }

    private static func handleMouseMoved(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // Arms the dead zone (side effect) and tracks input activity for the
        // outside-click passthrough timing. Hover itself is resolved by the
        // velocity-gated 60Hz poll (toggleHoverPoll), NOT here: driving
        // updateHover from the event tap ran the heavy per-tile work (highlight +
        // scroll + preview + traffic-light buttons) synchronously in the session
        // event-tap callback for every mouseMoved event, which both delayed
        // system-wide input and highlighted every tile a fast flick passed over.
        if isAllowedToReactToPointerMovement(cgEvent.location), isPointerInsideUi() {
            App.noteInputCaptureActivity("mouse-move")
        }
        return Unmanaged.passUnretained(cgEvent)
    }

    private static func handleOutsideUiMouseDown(_ button: String, _ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        let passThrough = App.inputCaptureIsOlderThan(RuntimeFlags.inputCapturePassthroughMs)
        logTapDecision(button, "down", cgEvent, absorbed: !passThrough, reason: passThrough ? "outsideUi-stale→hideUi-pass" : "outsideUi→hideUi")
        mouseDownTarget = nil
        mouseDownInsideSearchField = false
        outsideMouseDownPassedThroughButton = passThrough ? button : nil
        App.hideUi()
        return passThrough ? Unmanaged.passUnretained(cgEvent) : nil
    }

    private static func handleOutsideUiMouseUpIfNeeded(_ button: String, _ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        guard outsideMouseDownPassedThroughButton == button else { return nil }
        outsideMouseDownPassedThroughButton = nil
        mouseDownTarget = nil
        mouseDownInsideSearchField = false
        logTapDecision(button, "up", cgEvent, absorbed: false, reason: "outsideUi-after-pass")
        return Unmanaged.passUnretained(cgEvent)
    }

    static func resetDeadzone() {
        deadZoneInitialPosition = nil
        isAllowedToMouseHover = false
    }

    static func isAllowedToReactToPointerMovement(_ location: CGPoint) -> Bool {
        updateDeadzoneSituation(location)
        return isAllowedToMouseHover
    }

    private static func pointerLocationInWindow() -> NSPoint {
        TilesPanel.shared.mouseLocationOutsideOfEventStream
    }

    private static func isInsideUi(_ windowPoint: NSPoint) -> Bool {
        TilesPanel.shared.contentLayoutRect.contains(windowPoint)
    }

    private static func isPointerInsideUi() -> Bool {
        isInsideUi(pointerLocationInWindow())
    }

    private static func isPointerInsideSearchField() -> Bool {
        let searchField = TilesView.searchField
        if searchField.isHidden { return false }
        let point = searchField.convert(pointerLocationInWindow(), from: nil)
        return searchField.bounds.contains(point)
    }

    private static func findButton(at windowPoint: NSPoint) -> TrafficLightButton? {
        let overlay = TilesView.thumbnailOverView
        return overlay.findButton(overlay.convert(windowPoint, from: nil))
    }

    private static func findTile(at windowPoint: NSPoint) -> TileView? {
        let overlay = TilesView.thumbnailOverView
        return overlay.findTarget(overlay.convert(windowPoint, from: nil))
    }

    private static func findButtonUnderPointer() -> TrafficLightButton? {
        findButton(at: pointerLocationInWindow())
    }

    private static func findTileViewUnderPointer() -> TileView? {
        findTile(at: pointerLocationInWindow())
    }

    /// when using the trackpad, the user may swipe with a slight mistake. This will create a small cursor movement
    /// we ignore those, as they are not intended. Intended movements will be larger and not ignored
    private static func updateDeadzoneSituation(_ location: CGPoint) {
        guard let deadZoneInitialPosition else {
            deadZoneInitialPosition = location
            isAllowedToMouseHover = false
            return
        }
        let deltaX = location.x - deadZoneInitialPosition.x
        let deltaY = location.y - deadZoneInitialPosition.y
        if hypot(deltaX, deltaY) > 25 { isAllowedToMouseHover = true }
    }
}
