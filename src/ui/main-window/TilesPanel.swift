import Cocoa

class TilesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    static var maxPossibleThumbnailSize = NSSize.zero
    static var maxPossibleAppIconSize = NSSize.zero
    static var shared: TilesPanel!
    private var frozenTopCenter: NSPoint?
    private var highWaterHeight: CGFloat = 0
    /// A show waiting for WindowServer to report the panel visible (`windowDidChangeOcclusionState`).
    private var pendingShow: (startedAt: CFAbsoluteTime, orderedFrontAt: CFAbsoluteTime)?

    convenience init() {
        self.init(contentRect: .zero, styleMask: .nonactivatingPanel, backing: .buffered, defer: false)
        delegate = self
        isFloatingPanel = true
        animationBehavior = .none
        hidesOnDeactivate = false
        titleVisibility = .hidden
        backgroundColor = .clear
        TilesView.initialize()
        contentView! = TilesView.contentView
        // triggering AltTab before or during Space transition animation brings the window on the Space post-transition
        collectionBehavior = .canJoinAllSpaces
        // 2nd highest level possible; this allows the app to go on top of context menus
        // highest level is .screenSaver but makes drag and drop on top the main window impossible
        level = .popUpMenu
        // helps filter out this window from the thumbnails
        setAccessibilitySubrole(.unknown)
        // for VoiceOver
        setAccessibilityLabel(App.name)
        updateAppearance()
        Self.shared = self
    }

    func updateAppearance() {
        hasShadow = Appearance.enablePanelShadow
        appearance = NSAppearance(named: Appearance.currentTheme == .dark ? .vibrantDark : .vibrantLight)
    }

    func updateContents(_ preservedScrollOrigin: CGPoint?) {
        caTransaction {
            TilesView.updateItemsAndLayout(preservedScrollOrigin)
            guard App.appIsBeingUsed else { return }
            setContentSize(TilesView.contentView.frame.size)
            guard App.appIsBeingUsed else { return }
            repositionOrFreeze()
        }
        // prevent further AppKit work
        TilesView.clearNeedsLayout()
    }

    private func repositionOrFreeze() {
        let size = frame.size
        guard TilesView.isSearchModeOn else {
            NSScreen.preferred.repositionPanel(self)
            resetFrozenPosition()
            return
        }
        if size.height > highWaterHeight {
            NSScreen.preferred.repositionPanel(self)
            highWaterHeight = size.height
            frozenTopCenter = NSPoint(x: frame.midX, y: frame.maxY)
        } else if let topCenter = frozenTopCenter {
            setFrameOrigin(NSPoint(x: topCenter.x - size.width * 0.5, y: topCenter.y - size.height))
        }
    }

    func resetFrozenPosition() {
        frozenTopCenter = nil
        highWaterHeight = 0
    }

    override func orderOut(_ sender: Any?) {
        pendingShow = nil
        TilesView.clearNeedsLayout()
        if Preferences.fadeOutAnimation {
            NSAnimationContext.runAnimationGroup(
                { _ in animator().alphaValue = 0 },
                completionHandler: { super.orderOut(sender) }
            )
        } else {
            // orderOut requires WindowServer. Let's hide before calling it, in case it lags
            alphaValue = 0
            super.orderOut(sender)
        }
    }

    /// `showStartedAt`: when the keypress that led to this show was handled.
    func show(_ showStartedAt: CFAbsoluteTime) {
        updateAppearance()
        alphaValue = 1
        let alreadyOnScreen = isVisible && occlusionState.contains(.visible)
        pendingShow = alreadyOnScreen ? nil : (showStartedAt, CFAbsoluteTimeGetCurrent())
        makeKeyAndOrderFront(nil)
        ContextMenuEvents.toggle(true)
        CursorEvents.toggle(true)
        if alreadyOnScreen {
            DispatchQueue.main.async { TilesView.scrollView.flashScrollers() }
        }
    }

    /// The panel reached the screen: log the latency, then flash the scrollers. Flashed in the show's
    /// own transaction (as before), any animation the flash adds holds that transaction's completion
    /// (`panel render complete`) until it ends.
    private func shownOnScreen(_ shown: (startedAt: CFAbsoluteTime, orderedFrontAt: CFAbsoluteTime)) {
        let now = CFAbsoluteTimeGetCurrent()
        let sinceShowStart = shown.startedAt > 0 ? (now - shown.startedAt) * 1000 : -1
        Diagnostics.log("PANEL", String(format: "panel on screen: sinceShowStart=%.0fms sinceOrderFront=%.0fms windows=%d", sinceShowStart, (now - shown.orderedFrontAt) * 1000, Windows.list.count))
        logRunningAnimations("on screen")
        TilesView.scrollView.flashScrollers()
        DispatchQueue.main.async { self.logRunningAnimations("after scroller flash") }
    }

    /// Running animations in any of AltTab's windows; those added in the show's transaction delay
    /// `panel render complete`. An empty probe transaction tells a held completion from a late one.
    private func logRunningAnimations(_ moment: String) {
        guard Diagnostics.shouldLog("REFRESH") else { return }
        let found = NSApp.windows.flatMap { Self.runningAnimations($0) }
        Diagnostics.log("REFRESH", "panel animations \(moment): \(found.isEmpty ? "none" : found.prefix(8).joined(separator: ", "))")
        let probeAt = CFAbsoluteTimeGetCurrent()
        CATransaction.begin()
        CATransaction.setCompletionBlock { Diagnostics.log("REFRESH", String(format: "panel animations \(moment): empty probe transaction completed after %.0fms", (CFAbsoluteTimeGetCurrent() - probeAt) * 1000)) }
        CATransaction.commit()
    }

    private static func runningAnimations(_ window: NSWindow) -> [String] {
        guard var root = window.contentView?.layer else { return [] }
        while let parent = root.superlayer { root = parent }
        var found = [String]()
        var stack = [root]
        while let layer = stack.popLast() {
            for key in layer.animationKeys() ?? [] {
                let duration = layer.animation(forKey: key).map { String(format: "%.2fs", $0.duration) } ?? "?"
                found.append("\(type(of: window))/\(type(of: layer)):\(key)=\(duration)")
            }
            stack.append(contentsOf: layer.sublayers ?? [])
        }
        return found
    }

    static func maxThumbnailsWidth(_ screen: NSScreen = NSScreen.preferred) -> CGFloat {
        if Preferences.appearanceStyle == .titles,
           let readableWidth = TilesView.layoutCache.comfortableReadabilityWidth {
            return (
                min(
                    screen.frame.width * Appearance.maxWidthOnScreen,
                    readableWidth + Appearance.intraCellPadding * 2 + Appearance.appIconLabelSpacing + Appearance.iconSize
                    // widthOfLongestTitle + Appearance.intraCellPadding * 2 + Appearance.appIconLabelSpacing + Appearance.iconSize
                ) - Appearance.windowPadding * 2
            ).rounded()
        }
        return (screen.frame.width * Appearance.maxWidthOnScreen - Appearance.windowPadding * 2).rounded()
    }

    static func maxThumbnailsHeight(_ screen: NSScreen = NSScreen.preferred) -> CGFloat {
        return (screen.frame.height * Appearance.maxHeightOnScreen - Appearance.windowPadding * 2).rounded()
    }

    static func updateMaxPossibleThumbnailSize() {
        let (w, h) = NSScreen.screens.reduce((CGFloat.zero, CGFloat.zero)) { acc, screen in
            (max(acc.0, TileView.maxThumbnailWidth(screen) * screen.backingScaleFactor),
            max(acc.1, TileView.maxThumbnailHeight(screen) * screen.backingScaleFactor))
        }
        maxPossibleThumbnailSize = NSSize(width: w.rounded(), height: h.rounded())
    }

    static func updateMaxPossibleAppIconSize() {
        let (w, h) = NSScreen.screens.reduce((CGFloat.zero, CGFloat.zero)) { acc, screen in
            // in Thumbnails Appearance, AppIcons can be used for windowless apps, thus much bigger than the app icon near the title
            if Preferences.appearanceStyle == .thumbnails {
                return (max(acc.0, TileView.maxThumbnailWidth(screen) * screen.backingScaleFactor),
                    max(acc.1, TileView.maxThumbnailHeight(screen) * screen.backingScaleFactor))
            } else {
                let size = TileView.iconSize(screen)
                return (max(acc.0, size.width * screen.backingScaleFactor),
                    max(acc.1, size.height * screen.backingScaleFactor))
            }
        }
        maxPossibleAppIconSize = NSSize(width: w.rounded(), height: h.rounded())
    }
}

extension TilesPanel: NSWindowDelegate {
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard occlusionState.contains(.visible), let shown = pendingShow else { return }
        pendingShow = nil
        shownOnScreen(shown)
    }

    func windowDidResignKey(_ notification: Notification) {
        // other windows can steal key focus from alt-tab; we make sure that if it's active, if keeps key focus
        // dispatching to the main queue is necessary to introduce a delay in scheduling the makeKey; otherwise it is ignored
        DispatchQueue.main.async {
            if App.appIsBeingUsed {
                TilesPanel.shared.makeKeyAndOrderFront(nil)
            }
            MainMenu.toggle(true)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // we toggle the mainMenu off when showing the main window
        // this avoids command+q from quitting AltTab itself, or command+p from printing
        DispatchQueue.main.async {
            MainMenu.toggle(false)
            if TilesView.isSearchEditing {
                MainMenu.toggleEditMenu(true)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            Applications.manuallyRefreshAllWindows()
        }
    }
}
