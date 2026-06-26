import Cocoa
import Carbon.HIToolbox.Events

class CursorEvents {
    private static var eventTap: CFMachPort!
    private static var shouldBeEnabled: Bool!
    private static var mouseDownTarget: AnyObject?
    private static var mouseDownInsideSearchField = false
    private static var outsideMouseDownPassedThroughButton: String?
    static var deadZoneInitialPosition: CGPoint?
    static var isAllowedToMouseHover = true
    private static var hoverPollTimer: Timer?
    private static var lastHoverPollLocation: CGPoint?

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
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: enabled)
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
        guard let eventTap, shouldBeEnabled, !CGEvent.tapIsEnabled(tap: eventTap) else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        Logger.warning { "" }
    }

    private static func observe_() {
        let eventMask = [CGEventType.leftMouseDown, CGEventType.leftMouseUp, CGEventType.rightMouseDown, CGEventType.rightMouseUp, CGEventType.otherMouseDown, CGEventType.otherMouseUp, CGEventType.mouseMoved].reduce(CGEventMask(0), { $0 | (1 << $1.rawValue) })
        // CGEvent.tapCreate returns nil if ensureAccessibilityCheckboxIsChecked() didn't pass
        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: handleEvent,
            userInfo: nil)
        if let eventTap {
            toggle(false)
            let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0)
            // we run on main-thread directly since all we do is check NSEvent and UI coordinates, which we must do on main-thread
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        } else {
            App.restart()
        }
    }

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
                if shouldBeEnabled { CGEvent.tapEnable(tap: eventTap!, enable: true) }
                return Unmanaged.passUnretained(cgEvent)
            default: return Unmanaged.passUnretained(cgEvent)
        }
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
        mouseDownTarget = nil
        if let button = findButtonUnderPointer(), button === downTarget {
            button.onClick()
            logTapDecision("left", "up", cgEvent, absorbed: true, reason: "button")
            return nil
        }
        if let target = findTileViewUnderPointer(), target === downTarget {
            target.mouseUpCallback()
            logTapDecision("left", "up", cgEvent, absorbed: true, reason: "tile")
            return nil
        }
        logTapDecision("left", "up", cgEvent, absorbed: true, reason: "insideUi-noTarget")
        return nil
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

    private static func isPointerInsideUi() -> Bool {
        TilesPanel.shared.contentLayoutRect.contains(pointerLocationInWindow())
    }

    private static func isPointerInsideSearchField() -> Bool {
        let searchField = TilesView.searchField
        if searchField.isHidden { return false }
        let point = searchField.convert(pointerLocationInWindow(), from: nil)
        return searchField.bounds.contains(point)
    }

    private static func pointerInOverlay() -> (TileOverView, NSPoint) {
        let overlay = TilesView.thumbnailOverView
        return (overlay, overlay.convert(pointerLocationInWindow(), from: nil))
    }

    private static func findButtonUnderPointer() -> TrafficLightButton? {
        let (overlay, point) = pointerInOverlay()
        return overlay.findButton(point)
    }

    private static func findTileViewUnderPointer() -> TileView? {
        let (overlay, point) = pointerInOverlay()
        return overlay.findTarget(point)
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
