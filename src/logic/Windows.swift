import Cocoa

class Windows {
    static var list = [Window]()
    static var selectedWindowIndex = Int(0)
    static var selectedWindowTarget: String?
    static var hoveredWindowIndex: Int?
    // we use this to track if the focused window changed while alt-tab was open
    private static var lastFocusedWindowTarget: String?
    /// When AltTab initiates a focus change via SLPS + pin for a Parallels
    /// transition, Cocoa often fires a brief spurious `kAXFocusedWindowChanged`
    /// notification for the target app's PREVIOUSLY-key window before
    /// settling on our actual target. If we let that event through to
    /// `updateLastFocusOrder`, the recency list gets a stale window
    /// promoted to position 0, and a user alternating A↔B can end up
    /// with C (a third window) being offered as the next target.
    ///
    /// `altTabFocusTarget` is set to the target window for the duration
    /// of `altTabFocusGuardMs` milliseconds. During that window,
    /// `AccessibilityEvents.focusedWindowChanged` suppresses recency
    /// updates for any window OTHER than this target.
    static var altTabFocusTarget: Window?
    static var altTabFocusTargetUntil: CFAbsoluteTime = 0
    // Guard must cover: Parallels' timer-driven re-activation (~500-1500ms),
    // our RERAISE at 400/700/1000ms, AND the source-hide duration (3s).
    // Aligned to ZENFORCE auto-stop (5s) so a late AX activation can't slip
    // through the gap. User clicks are detected via mouse monitor and
    // bypass the guard.
    static let altTabFocusGuardMs: Double = 5000
    /// Bumped on every Parallels-involved focus transition. Delayed
    /// snapshot-restore blocks check this and skip if a newer transition
    /// has started, so a late restore can't clobber the user's latest
    /// state.
    static var parallelsTransitionGeneration: UInt64 = 0

    /// Called at AltTab session start. Deterministically sets recency so
    /// position 0 is the current frontmost window and position 1 is the
    /// PREVIOUS session's source window (the window the user was on
    /// before switching to the current one). Everything else is re-indexed
    /// to 2, 3, … preserving relative recency. This ensures the switcher
    /// always shows [current, previous, …] regardless of any spurious
    /// AX events that may have drifted the list between sessions.
    static func normalizeFocusOrderAtSessionStart(currentWid: CGWindowID?, previousWid: CGWindowID?) {
        guard let currentWid,
              let currentWindow = (list.first { $0.cgWindowId == currentWid }) else { return }
        let previousWindow: Window? = {
            guard let previousWid, previousWid != currentWid else { return nil }
            return list.first { $0.cgWindowId == previousWid }
        }()
        setTargetAndSourceAsMostRecent(target: currentWindow, source: previousWindow)
    }

    @discardableResult
    static func syncFocusOrderWithLiveFrontmostWindow() -> CGWindowID? {
        let startedAt = CFAbsoluteTimeGetCurrent()
        guard let window = liveFrontmostWindow() else {
            logLiveFrontmostSync(startedAt, nil)
            return nil
        }
        window.application.focusedWindow = window
        Applications.frontmostPid = window.application.pid
        _ = updateLastFocusOrder(window)
        logLiveFrontmostSync(startedAt, window)
        return window.cgWindowId
    }

    private static func liveFrontmostWindow() -> Window? {
        let workspaceFrontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let frontPid = workspaceFrontPid ?? Applications.frontmostPid
        let topZWindow = topKnownZOrderWindow()
        if let guardedTarget = activeGuardedTarget(frontPid),
           zOrderFocusQuietRemainingMs() > 0 || topZWindow == nil || topZWindow === guardedTarget {
            return guardedTarget
        }
        if let topZWindow {
            return topZWindow
        }
        if let singleWindow = singleTrackedWindowForFrontApp(frontPid) { return singleWindow }
        if let cachedFocusedWindow = cachedFocusedWindow(frontPid) { return cachedFocusedWindow }
        if UserDefaults.standard.bool(forKey: "forceAxFocusedWindowAtSessionStart"),
           let axWindow = liveAxFocusedWindow(frontPid) { return axWindow }
        return nil
    }

    private static func logLiveFrontmostSync(_ startedAt: CFAbsoluteTime, _ window: Window?) {
        let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
        Diagnostics.log("REFRESH", String(format: "live frontmost sync: %.1fms wid=%@ app=%@", ms, window?.cgWindowId?.description ?? "nil", window?.application.localizedName ?? "?"))
    }

    private static func singleTrackedWindowForFrontApp(_ frontPid: pid_t?) -> Window? {
        guard let frontPid else { return nil }
        var singleWindow: Window?
        for window in list where window.application.pid == frontPid && !window.isWindowlessApp {
            guard singleWindow == nil else { return nil }
            singleWindow = window
        }
        return singleWindow
    }

    private static func cachedFocusedWindow(_ frontPid: pid_t?) -> Window? {
        guard let frontPid,
              let app = Applications.list.first(where: { $0.pid == frontPid }) else { return nil }
        return app.focusedWindow
    }

    private static func activeGuardedTarget(_ frontPid: pid_t?) -> Window? {
        guard CFAbsoluteTimeGetCurrent() < altTabFocusTargetUntil,
              let target = altTabFocusTarget,
              target.application.pid == frontPid else { return nil }
        return target
    }

    private static func liveAxFocusedWindow(_ pid: pid_t?) -> Window? {
        guard let pid,
              let app = Applications.list.first(where: { $0.pid == pid }),
              let appAxElement = app.axUiElement,
              let focusedAxElement = try? appAxElement.attributes([kAXFocusedWindowAttribute]).focusedWindow,
              let focusedWid = try? focusedAxElement.cgWindowId() else { return nil }
        return list.first { $0.isEqualRobust(focusedAxElement, focusedWid) }
    }

    private static func topKnownZOrderWindow() -> Window? {
        let maxAgeMs = UserDefaults.standard.object(forKey: "zOrderCacheMaxAgeMs") as? Double ?? 200
        guard let snapshot = cachedZOrderSnapshot(maxAgeMs: maxAgeMs) else {
            Diagnostics.log("REFRESH", "z-order cache unavailable/stale; falling back to AX-focused window")
            return nil
        }
        let windowsById = Dictionary(uniqueKeysWithValues: list.compactMap { window -> (CGWindowID, Window)? in
            guard let wid = window.cgWindowId else { return nil }
            return (wid, window)
        })
        for entry in snapshot.entries.prefix(64) {
            if let window = windowsById[entry.wid] {
                Diagnostics.log("REFRESH", String(format: "z-order cache hit: age=%.1fms gen=%llu wid=%u app=%@", snapshot.ageMs, snapshot.generation, entry.wid, window.application.localizedName ?? "?"))
                return window
            }
        }
        return nil
    }

    /// Set `target` to lastFocusOrder 0 AND `source` (if provided) to 1,
    /// with all other windows shifted to 2, 3, … preserving their
    /// relative recency. Used for Parallels-involved transitions where
    /// ordinary `updateLastFocusOrder(target)` can leave a corrupted
    /// window at position 1 (if a spurious AX event had previously
    /// promoted it). Making the ordering deterministic from the known
    /// source+target is more robust than trusting the prior list state.
    static func setTargetAndSourceAsMostRecent(target: Window, source: Window?) {
        let others = list.filter { $0 !== target && $0 !== source }
            .sorted { $0.lastFocusOrder < $1.lastFocusOrder }
        target.lastFocusOrder = 0
        var nextOrder = 1
        if let source {
            source.lastFocusOrder = nextOrder
            nextOrder += 1
        }
        for w in others {
            w.lastFocusOrder = nextOrder
            nextOrder += 1
        }
    }

    static func nextDisplayedFocusWindowId(after currentWid: CGWindowID?) -> CGWindowID? {
        list
            .filter { shouldDisplay($0) && $0.cgWindowId != currentWid }
            .sorted { $0.lastFocusOrder < $1.lastFocusOrder }
            .first?
            .cgWindowId
    }

    /// Recent focus targets with intended z-order. The guard periodically
    /// verifies actual z-order matches intent and re-raises if needed.
    struct ZOrderIntent {
        let wid: CGWindowID
        let pid: pid_t
        let timestamp: CFAbsoluteTime
        weak var window: Window?
        var raiseAttempts: Int = 0
        var wasEverAtZ0: Bool = false
        var expectedRestoreAttempts: Int = 0
        var lastExpectedRestoreAt: CFAbsoluteTime = 0
        /// Snapshot of the top window-list z-order taken BEFORE we
        /// fired any focus call. Used to compute the *expected*
        /// post-focus order = [target] + preZ.filter{ != target }.
        /// After target reaches z0 the first time, we walk this and
        /// pairwise-CGSOrderWindow each entry to its expected slot,
        /// undoing any sibling-promotion side-effects of process-level
        /// activation.
        var preZRanking: [PreZEntry] = []
        static let maxRaiseAttempts = 6
        static let maxExpectedRestoreAttempts = 6
    }

    struct PreZEntry {
        let wid: CGWindowID
        let pid: pid_t
        let owner: String
        var rank: Int = Int.max
        var lastSeenAt: CFAbsoluteTime = 0
        var lastRankChangedAt: CFAbsoluteTime = 0
    }

    /// Capture visible app-level windows in current z-order.
    /// Same filtering as enforceZOrder/SYSZ: skip overlay/system owners,
    /// near-zero alpha, tiny widths, and non-zero compositor layers.
    /// Default 200 covers any realistic working set; ZRESTORE needs the
    /// full ranking (not just top-8) so corrections below the fold still
    /// reflect the user-expected order. CGWindowList itself is the only
    /// real cost; filtering and an Array of structs are free in
    /// comparison, so there is no perf reason to truncate aggressively.
    static func captureTopZRanking(maxCount: Int = 200, timestamp: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> [PreZEntry] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let blocklist: Set<String> = [
            "Window Server", "Control Center", "Dock", "AltTab",
            "Notification Center", "SystemUIServer", "Spotlight",
            "Menubar", "Wallpaper", "CursorUIViewService",
            "LocalAuthenticationRemoteService",
        ]
        var out: [PreZEntry] = []
        for w in info {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            if blocklist.contains(owner) { continue }
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha < 0.1 { continue }
            if let bounds = w[kCGWindowBounds as String] as? [String: Any],
               let width = bounds["Width"] as? Double, width < 40 { continue }
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            if layer != 0 { continue }
            let wid = (w[kCGWindowNumber as String] as? Int) ?? 0
            let pid = (w[kCGWindowOwnerPID as String] as? Int32) ?? 0
            out.append(PreZEntry(wid: CGWindowID(wid), pid: pid, owner: owner, rank: out.count, lastSeenAt: timestamp, lastRankChangedAt: timestamp))
            if out.count >= maxCount { break }
        }
        return out
    }
    static var recentZOrderIntents = [ZOrderIntent]()
    private static let zOrderCacheLock = NSLock()
    private static var zOrderCacheTimer: DispatchSourceTimer?
    private static var zOrderCacheByWid = [CGWindowID: PreZEntry]()
    private static var zOrderCacheTopSnapshot = [PreZEntry]()
    private static var zOrderCacheFullSnapshot = [PreZEntry]()
    private static var zOrderCacheTopUpdatedAt: CFAbsoluteTime = 0
    private static var zOrderCacheFullUpdatedAt: CFAbsoluteTime = 0
    private static var zOrderCacheGeneration: UInt64 = 0
    private static var zOrderLifecycleGeneration: Int64 = 0
    private static var zOrderFocusGeneration: Int64 = 0
    private static var zOrderFocusQuietUntilNs: Int64 = 0
    private static var zOrderEnforcementTimer: DispatchSourceTimer?
    private static var zOrderEnforcementGeneration: UInt64 = 0
    private static var queuedAxRecoveryWids = Set<CGWindowID>()
    private static var syntheticFocusClickIgnoreUntil: CFAbsoluteTime = 0
    private static var syntheticFocusClickTimestamp: TimeInterval = 0

    static func startZOrderCache() {
        guard RuntimeFlags.zOrderCacheEnabled else {
            Diagnostics.log("INIT", "z-order cache disabled by zOrderCacheEnabled=false")
            return
        }
        guard zOrderCacheTimer == nil else { return }
        let intervalMs = zOrderCacheIntervalMs()
        let timer = DispatchSource.makeTimerSource(queue: BackgroundWork.zOrderCacheQueue.strongUnderlyingQueue)
        timer.schedule(deadline: .now(),
                       repeating: .milliseconds(intervalMs),
                       leeway: .milliseconds(5))
        timer.setEventHandler {
            guard BackgroundWork.zOrderCacheQueue.operationCount == 0 else { return }
            BackgroundWork.zOrderCacheQueue.addOperation {
                refreshZOrderCacheRespectingFocus(false, topOnly: false, lifecycleGeneration: nil)
            }
        }
        timer.resume()
        zOrderCacheTimer = timer
        Diagnostics.log("INIT", "z-order cache started interval=\(intervalMs)ms")
    }

    static func stopZOrderCache() {
        zOrderCacheTimer?.cancel()
        zOrderCacheTimer = nil
    }

    static func requestZOrderCacheRefresh(full: Bool = false, delayMs: Int = 0, lifecycleGeneration: Int64? = nil, topOnly: Bool = false) {
        guard RuntimeFlags.zOrderCacheEnabled else { return }
        guard BackgroundWork.zOrderCacheQueue != nil else { return }
        BackgroundWork.zOrderCacheQueue.addOperationAfter(deadline: .now() + .milliseconds(delayMs)) {
            refreshZOrderCacheRespectingFocus(full, topOnly: topOnly, lifecycleGeneration: lifecycleGeneration)
        }
    }

    static func requestZOrderReview(reason: String, wid: CGWindowID = 0, invalidate: Bool = false, fullDelayMs: Int = 400) {
        guard RuntimeFlags.zOrderCacheEnabled else { return }
        if reason == "alttab-focus-intent" {
            extendZOrderFocusQuietPeriod()
        }
        if invalidate {
            invalidateZOrderCacheEntry(wid)
        }
        let generation = nextZOrderLifecycleGeneration()
        Diagnostics.log("REFRESH", "z-order review reason=\(reason) wid=\(wid) invalidate=\(invalidate) gen=\(generation)")
        requestZOrderCacheRefresh(full: false, delayMs: 0, topOnly: true)
        requestZOrderCacheRefresh(full: false, delayMs: 80, lifecycleGeneration: generation, topOnly: true)
        if fullDelayMs >= 0 {
            requestZOrderCacheRefresh(full: true, delayMs: fullDelayMs, lifecycleGeneration: generation)
        }
    }

    static func requestZOrderTopReview(reason: String, wid: CGWindowID = 0, invalidate: Bool = false, secondDelayMs: Int = 120) {
        guard RuntimeFlags.zOrderCacheEnabled else { return }
        if invalidate {
            invalidateZOrderCacheEntry(wid)
        }
        Diagnostics.log("REFRESH", "z-order top review reason=\(reason) wid=\(wid) invalidate=\(invalidate)")
        requestZOrderCacheRefresh(full: false, delayMs: 0, topOnly: true)
        requestZOrderCacheRefresh(full: false, delayMs: secondDelayMs, topOnly: true)
    }

    static func requestZOrderReview(afterWindowLifecycleEvent reason: String, wid: CGWindowID) {
        requestZOrderReview(reason: reason, wid: wid, invalidate: wid != 0, fullDelayMs: 400)
    }

    private static func invalidateZOrderCacheEntry(_ wid: CGWindowID) {
        guard wid != 0 else { return }
        let block = {
            zOrderCacheLock.lock()
            zOrderCacheByWid.removeValue(forKey: wid)
            zOrderCacheTopSnapshot.removeAll { $0.wid == wid }
            zOrderCacheFullSnapshot.removeAll { $0.wid == wid }
            zOrderCacheGeneration &+= 1
            zOrderCacheLock.unlock()
        }
        if Thread.isMainThread {
            guard BackgroundWork.zOrderCacheQueue != nil else { return }
            BackgroundWork.zOrderCacheQueue.addOperation(block)
            return
        }
        block()
    }

    private static func withZOrderCacheLock<T>(_ block: () -> T) -> T? {
        if Thread.isMainThread {
            guard zOrderCacheLock.try() else { return nil }
        } else {
            zOrderCacheLock.lock()
        }
        defer { zOrderCacheLock.unlock() }
        return block()
    }

    private static func liveZOrderSnapshotOffMain(maxCount: Int) -> [PreZEntry] {
        guard !Thread.isMainThread else {
            requestZOrderCacheRefresh(full: false, delayMs: 0, topOnly: true)
            return []
        }
        return captureTopZRanking(maxCount: maxCount)
    }

    private static func liveFullZOrderSnapshotForIntent() -> [PreZEntry] {
        guard !Thread.isMainThread else {
            requestZOrderCacheRefresh(full: true, delayMs: 0)
            Diagnostics.log("ZRESTORE", "preZ unavailable on main; queued cache refresh instead of blocking")
            return []
        }
        return captureTopZRanking()
    }

    private static func extendZOrderFocusQuietPeriod() {
        let quietUntil = zOrderFocusQuietDeadlineNs()
        while true {
            let current = OSAtomicAdd64Barrier(0, &zOrderFocusQuietUntilNs)
            guard quietUntil > current else { return }
            if OSAtomicCompareAndSwap64Barrier(current, quietUntil, &zOrderFocusQuietUntilNs) { return }
        }
    }

    private static func zOrderFocusQuietRemainingMs() -> Int {
        let deadline = OSAtomicAdd64Barrier(0, &zOrderFocusQuietUntilNs)
        let now = zOrderNowNs()
        guard deadline > now else { return 0 }
        return Int((deadline - now + 999_999) / 1_000_000)
    }

    static func focusQuietRemainingMs() -> Int {
        zOrderFocusQuietRemainingMs()
    }

    private static func zOrderNowNs() -> Int64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return now > UInt64(Int64.max) ? Int64.max : Int64(now)
    }

    private static func zOrderFocusQuietDeadlineNs() -> Int64 {
        let now = zOrderNowNs()
        let delta = Int64(zOrderFocusQuietMs()) * 1_000_000
        return now > Int64.max - delta ? Int64.max : now + delta
    }

    private static func nextZOrderLifecycleGeneration() -> Int64 {
        OSAtomicIncrement64Barrier(&zOrderLifecycleGeneration)
    }

    private static func isCurrentZOrderLifecycleGeneration(_ generation: Int64) -> Bool {
        generation == OSAtomicAdd64Barrier(0, &zOrderLifecycleGeneration)
    }

    private static func refreshZOrderCache(_ forceFull: Bool, topOnly: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        let fullUpdatedAt = withZOrderCacheLock { zOrderCacheFullUpdatedAt } ?? 0
        let shouldRefreshFull = !topOnly && (forceFull || now - fullUpdatedAt > Double(zOrderCacheFullIntervalMs()) / 1000)
        let snapshot = captureTopZRanking(maxCount: shouldRefreshFull ? zOrderCacheFullMaxCount() : zOrderCacheTopMaxCount(), timestamp: now)
        zOrderCacheLock.lock()
        let merged = mergeZOrderCache(snapshot, now)
        zOrderCacheByWid = merged
        zOrderCacheTopSnapshot = snapshot.compactMap { merged[$0.wid] }
        zOrderCacheTopUpdatedAt = now
        if shouldRefreshFull {
            zOrderCacheFullSnapshot = snapshot.compactMap { merged[$0.wid] }
            zOrderCacheFullUpdatedAt = now
        }
        zOrderCacheGeneration &+= 1
        zOrderCacheLock.unlock()
    }

    private static func refreshZOrderCacheRespectingFocus(_ forceFull: Bool, topOnly: Bool, lifecycleGeneration: Int64?) {
        if let lifecycleGeneration, !isCurrentZOrderLifecycleGeneration(lifecycleGeneration) { return }
        let quietMs = zOrderFocusQuietRemainingMs()
        guard quietMs == 0 else {
            requestZOrderCacheRefresh(full: forceFull, delayMs: quietMs, lifecycleGeneration: lifecycleGeneration, topOnly: topOnly)
            return
        }
        refreshZOrderCache(forceFull, topOnly: topOnly)
    }

    private static func mergeZOrderCache(_ snapshot: [PreZEntry], _ now: CFAbsoluteTime) -> [CGWindowID: PreZEntry] {
        var merged = zOrderCacheByWid.filter { now - $0.value.lastSeenAt < 30 }
        for entry in snapshot {
            var updated = entry
            if let old = merged[entry.wid], old.rank == entry.rank {
                updated.lastRankChangedAt = old.lastRankChangedAt
            } else {
                updated.lastRankChangedAt = now
            }
            updated.lastSeenAt = now
            merged[entry.wid] = updated
        }
        return merged
    }

    private static func cachedZOrderSnapshot(maxAgeMs: Double) -> (entries: [PreZEntry], ageMs: Double, generation: UInt64)? {
        guard RuntimeFlags.zOrderCacheEnabled else { return nil }
        guard let values = withZOrderCacheLock({
            (zOrderCacheTopSnapshot, zOrderCacheTopUpdatedAt, zOrderCacheGeneration)
        }) else { return nil }
        let snapshot = values.0
        let updatedAt = values.1
        let generation = values.2
        guard updatedAt > 0 else { return nil }
        let ageMs = (CFAbsoluteTimeGetCurrent() - updatedAt) * 1000
        guard ageMs <= maxAgeMs else { return nil }
        return (snapshot, ageMs, generation)
    }

    private static func cachedFullZOrderSnapshot(maxAgeMs: Double) -> (entries: [PreZEntry], ageMs: Double, generation: UInt64)? {
        guard RuntimeFlags.zOrderCacheEnabled else { return nil }
        guard let values = withZOrderCacheLock({
            (zOrderCacheFullSnapshot, zOrderCacheFullUpdatedAt, zOrderCacheGeneration)
        }) else { return nil }
        let snapshot = values.0
        let updatedAt = values.1
        let generation = values.2
        guard updatedAt > 0 else { return nil }
        let ageMs = (CFAbsoluteTimeGetCurrent() - updatedAt) * 1000
        guard ageMs <= maxAgeMs else { return nil }
        return (snapshot, ageMs, generation)
    }

    static func cachedFullZOrderSnapshotForFocus() -> [PreZEntry]? {
        cachedFullZOrderSnapshot(maxAgeMs: 1500)?.entries
    }

    static func cachedZOrderSnapshotForFocus() -> [PreZEntry]? {
        cachedZOrderSnapshot(maxAgeMs: 250)?.entries ?? cachedFullZOrderSnapshotForFocus()
    }

    static func zOrderSnapshotForFocus() -> [PreZEntry] {
        cachedZOrderSnapshotForFocus() ?? liveZOrderSnapshotOffMain(maxCount: 64)
    }

    static func cachedTopZOrderWid(maxAgeMs: Double = 250) -> CGWindowID? {
        cachedZOrderSnapshot(maxAgeMs: maxAgeMs)?.entries.first?.wid
    }

    private static func zRankingForRepair(maxCount: Int) -> [PreZEntry] {
        if let cached = cachedZOrderSnapshot(maxAgeMs: 120), !cached.entries.isEmpty {
            return Array(cached.entries.prefix(maxCount))
        }
        return liveZOrderSnapshotOffMain(maxCount: maxCount)
    }

    static func visibleWindowCount(pid: pid_t) -> Int {
        list.reduce(0) { count, window in
            guard window.application.pid == pid,
                  !window.isWindowlessApp,
                  !window.isMinimized else { return count }
            return count + 1
        }
    }

    @discardableResult
    static func nextZOrderFocusGeneration() -> Int64 {
        extendZOrderFocusQuietPeriod()
        return OSAtomicIncrement64Barrier(&zOrderFocusGeneration)
    }

    static func currentZOrderFocusGeneration() -> Int64 {
        OSAtomicAdd64Barrier(0, &zOrderFocusGeneration)
    }

    static func isCurrentZOrderFocusGeneration(_ generation: Int64) -> Bool {
        generation == OSAtomicAdd64Barrier(0, &zOrderFocusGeneration)
    }

    static func restoreExpectedZOrderForFocus(targetWid: CGWindowID, targetPid: pid_t, preZ: [PreZEntry]) {
        guard RuntimeFlags.zOrderFixesEnabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) {
            _ = restoreExpectedZOrder(targetWid: targetWid, targetPid: targetPid, preZ: preZ)
            requestZOrderCacheRefresh(full: true, delayMs: 0)
        }
    }

    static func retryNativeFocusTargetIfNeeded(targetWid: CGWindowID, targetPid: pid_t, delayMs: Int) {
        guard RuntimeFlags.zOrderFixesEnabled else { return }
        let generation = currentZOrderFocusGeneration()
        BackgroundWork.zOrderCacheQueue.addOperationAfter(deadline: .now() + .milliseconds(delayMs)) {
            guard isCurrentZOrderFocusGeneration(generation) else { return }
            let actual = zRankingForRepair(maxCount: 8)
            guard actual.first?.wid != targetWid else {
                requestZOrderCacheRefresh(full: false)
                return
            }
            let top = actual.first.map { "#\($0.wid) \($0.owner)" } ?? "nil"
            if let blockerWid = actual.first?.wid {
                let pairErr = CGSOrderWindow(CGS_CONNECTION, targetWid, CGSWindowOrderingMode.above.rawValue, blockerWid)
                if pairErr == .success {
                    Diagnostics.log("ZRESTORE", "native target-only pair retry target=#\(targetWid) above=#\(blockerWid) top=\(top) CGS=0")
                    requestZOrderCacheRefresh(full: false, delayMs: 0)
                    return
                }
            }
            let orderErr = CGSOrderWindow(CGS_CONNECTION, targetWid, CGSWindowOrderingMode.above.rawValue, 0)
            Diagnostics.log("ZRESTORE", "native target-only retry target=#\(targetWid) top=\(top) CGS=\(orderErr.rawValue)")
            guard orderErr != .success else {
                requestZOrderCacheRefresh(full: false, delayMs: 0)
                return
            }
            DispatchQueue.main.async {
                guard isCurrentZOrderFocusGeneration(generation) else { return }
                guard let target = list.first(where: { $0.cgWindowId == targetWid }) else { return }
                BackgroundWork.accessibilityCommandsQueue.addOperation { [weak target] in
                    guard isCurrentZOrderFocusGeneration(generation) else { return }
                    guard let target else { return }
                    if let appAx = target.application.axUiElement, let windowAx = target.axUiElement {
                        AXUIElementSetMessagingTimeout(appAx, 0.25)
                        AXUIElementSetMessagingTimeout(windowAx, 0.25)
                        try? appAx.setAttribute(kAXFocusedWindowAttribute, windowAx)
                    }
                    try? target.axUiElement?.focusWindow()
                    Diagnostics.log("ZRESTORE", "native target-only AX retry done target=#\(targetWid) pid=\(targetPid)")
                    requestZOrderCacheRefresh(full: false, delayMs: 0)
                }
            }
        }
    }

    static func restoreNativeTargetSiblingOrderForFocus(targetWid: CGWindowID, targetPid: pid_t, preZ: [PreZEntry]) {
        guard RuntimeFlags.zOrderFixesEnabled else { return }
        let generation = currentZOrderFocusGeneration()
        for delayMs in [80, 180, 360] {
            BackgroundWork.zOrderCacheQueue.addOperationAfter(deadline: .now() + .milliseconds(delayMs)) {
                guard isCurrentZOrderFocusGeneration(generation) else { return }
                restoreNativeTargetSiblingOrder(targetWid: targetWid, targetPid: targetPid, preZ: preZ, generation: generation)
            }
        }
    }

    static func restoreNativeExpectedSiblingOrderImmediately(targetWid: CGWindowID, targetPid: pid_t, preZ: [PreZEntry]) {
        guard RuntimeFlags.zOrderFixesEnabled else { return }
        restoreNativeExpectedSiblingOrder(targetWid: targetWid, targetPid: targetPid, preZ: preZ, generation: currentZOrderFocusGeneration())
    }

    private static func restoreNativeExpectedSiblingOrder(targetWid: CGWindowID, targetPid: pid_t, preZ: [PreZEntry], generation: Int64) {
        let expectedSiblings = expectedNativeSiblingGroup(targetWid: targetWid, targetPid: targetPid, preZ: preZ)
        guard !expectedSiblings.isEmpty else { return }
        let actual = zRankingForRepair(maxCount: 64)
        let actualWids = actual.map { $0.wid }
        guard actual.first?.wid == targetWid else { return }
        guard let divider = preZ.first(where: { $0.wid != targetWid && $0.pid != targetPid }),
              let dividerIndex = actualWids.firstIndex(of: divider.wid) else { return }
        let expectedWids = expectedSiblings.map { $0.wid }
        let prefixWids = Array(actualWids.dropFirst().prefix(expectedWids.count))
        let misplaced = expectedWids.contains { wid in
            guard let index = actualWids.firstIndex(of: wid) else { return false }
            return index > dividerIndex
        }
        guard misplaced || prefixWids != expectedWids else { return }
        DispatchQueue.main.async {
            guard isCurrentZOrderFocusGeneration(generation) else { return }
            let siblingWindows = expectedWids.compactMap { wid in list.first { $0.cgWindowId == wid } }
            guard siblingWindows.count == expectedWids.count,
                  let targetWindow = list.first(where: { $0.cgWindowId == targetWid }) else { return }
            BackgroundWork.accessibilityCommandsQueue.addOperation {
                guard isCurrentZOrderFocusGeneration(generation) else { return }
                let startedAt = CFAbsoluteTimeGetCurrent()
                for window in siblingWindows.reversed() {
                    raiseSpecificWindowViaAx(window)
                }
                raiseSpecificWindowViaAx(targetWindow)
                let ms = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
                Diagnostics.log("ZRESTORE", String(format: "native expected sibling repair target=#%u siblings=%@ divider=#%u ms=%.1f", targetWid, expectedWids.map { "#\($0)" }.joined(separator: ","), divider.wid, ms))
                requestZOrderCacheRefresh(full: false)
            }
        }
    }

    static func restoreNativeExpectedSiblingOrderForFocus(targetWid: CGWindowID, targetPid: pid_t, preZ: [PreZEntry]) {
        guard RuntimeFlags.zOrderFixesEnabled else { return }
        let generation = currentZOrderFocusGeneration()
        for delayMs in [0, 35, 100, 220] {
            BackgroundWork.zOrderCacheQueue.addOperationAfter(deadline: .now() + .milliseconds(delayMs)) {
                guard isCurrentZOrderFocusGeneration(generation) else { return }
                restoreNativeExpectedSiblingOrder(targetWid: targetWid, targetPid: targetPid, preZ: preZ, generation: generation)
            }
        }
    }

    private static func expectedNativeSiblingGroup(targetWid: CGWindowID, targetPid: pid_t, preZ: [PreZEntry]) -> [PreZEntry] {
        var siblings = [PreZEntry]()
        for entry in preZ {
            if entry.wid == targetWid { continue }
            guard entry.pid == targetPid else { break }
            siblings.append(entry)
        }
        return siblings
    }

    private static func restoreNativeTargetSiblingOrder(targetWid: CGWindowID, targetPid: pid_t, preZ: [PreZEntry], generation: Int64) {
        let actual = zRankingForRepair(maxCount: 64)
        let actualWids = actual.map { $0.wid }
        guard actual.first?.wid == targetWid,
              let divider = preZ.first(where: { $0.wid != targetWid && $0.pid != targetPid && actualWids.contains($0.wid) }),
              let dividerIndex = actualWids.firstIndex(of: divider.wid) else { return }
        let expectedSiblingWids = Set(expectedNativeSiblingGroup(targetWid: targetWid, targetPid: targetPid, preZ: preZ).map { $0.wid })
        let raisedSiblings = actual.prefix(dividerIndex).dropFirst().filter { $0.pid == targetPid && !expectedSiblingWids.contains($0.wid) }
        guard !raisedSiblings.isEmpty else { return }
        let orderErr = CGSOrderWindow(CGS_CONNECTION, divider.wid, CGSWindowOrderingMode.below.rawValue, targetWid)
        Diagnostics.log("ZRESTORE", "native sibling demote target=#\(targetWid) divider=#\(divider.wid) siblings=\(raisedSiblings.map { $0.wid }) CGS=\(orderErr.rawValue)")
        guard orderErr != .success else {
            requestZOrderCacheRefresh(full: false)
            return
        }
        DispatchQueue.main.async {
            guard isCurrentZOrderFocusGeneration(generation) else { return }
            guard let dividerWindow = list.first(where: { $0.cgWindowId == divider.wid }),
                  let targetWindow = list.first(where: { $0.cgWindowId == targetWid }) else { return }
            BackgroundWork.accessibilityCommandsQueue.addOperation { [weak dividerWindow, weak targetWindow] in
                guard isCurrentZOrderFocusGeneration(generation) else { return }
                if let dividerWindow {
                    focusSpecificWindowViaAx(dividerWindow)
                }
                if let targetWindow {
                    focusSpecificWindowViaAx(targetWindow)
                }
                Diagnostics.log("ZRESTORE", "native sibling AX demote done target=#\(targetWid) divider=#\(divider.wid)")
                requestZOrderCacheRefresh(full: false, delayMs: 0)
            }
        }
    }

    private static func focusSpecificWindowViaAx(_ window: Window) {
        guard let windowAx = window.axUiElement else { return }
        if let appAx = window.application.axUiElement {
            AXUIElementSetMessagingTimeout(appAx, 0.25)
            AXUIElementSetMessagingTimeout(windowAx, 0.25)
            try? appAx.setAttribute(kAXFocusedWindowAttribute, windowAx)
        }
        try? windowAx.focusWindow()
    }

    private static func raiseSpecificWindowViaAx(_ window: Window) {
        guard let windowAx = window.axUiElement else { return }
        AXUIElementSetMessagingTimeout(windowAx, 0.25)
        try? windowAx.performAction(kAXRaiseAction as String)
    }

    private static func zOrderCacheIntervalMs() -> Int {
        let value = UserDefaults.standard.object(forKey: "zOrderCacheIntervalMs") as? Int ?? 150
        return min(max(value, 50), 500)
    }

    private static func zOrderCacheFullIntervalMs() -> Int {
        let value = UserDefaults.standard.object(forKey: "zOrderCacheFullIntervalMs") as? Int ?? 1000
        return min(max(value, zOrderCacheIntervalMs()), 5000)
    }

    private static func zOrderCacheTopMaxCount() -> Int {
        let value = UserDefaults.standard.object(forKey: "zOrderCacheTopMaxCount") as? Int ?? 32
        return min(max(value, 8), 128)
    }

    private static func zOrderCacheFullMaxCount() -> Int {
        let value = UserDefaults.standard.object(forKey: "zOrderCacheFullMaxCount") as? Int ?? 200
        return min(max(value, zOrderCacheTopMaxCount()), 500)
    }

    private static func zOrderFocusQuietMs() -> Int {
        let value = UserDefaults.standard.object(forKey: "zOrderFocusQuietMs") as? Int ?? 450
        return min(max(value, 0), 600)
    }

    static func armAltTabFocusGuard(for target: Window) {
        altTabFocusTarget = target
        altTabFocusTargetUntil = CFAbsoluteTimeGetCurrent() + altTabFocusGuardMs / 1000.0
        counterRaiseCount = 0
        guard RuntimeFlags.zOrderFixesEnabled else { return }
        // Record this target's intended z-position (topmost)
        if let wid = target.cgWindowId {
            let now = CFAbsoluteTimeGetCurrent()
            // Prune entries older than 5s
            recentZOrderIntents.removeAll { now - $0.timestamp > 3.0 }
            // Preserve preZRanking from a prior recent call for the same
            // wid. atomicallyPinAndActivate calls us BEFORE SLPS fires
            // (correct snapshot moment), then manuallyUpdateFocusOrderForParallelsTransition
            // calls us again AFTER SLPS already started moving the
            // z-order — re-snapshotting at that point would capture a
            // mid-transition state. Reuse the first call's snapshot.
            let prior = recentZOrderIntents.first { $0.wid == wid }
            let preZ: [PreZEntry]
            if let prior, !prior.preZRanking.isEmpty {
                preZ = prior.preZRanking
            } else if let cached = cachedFullZOrderSnapshot(maxAgeMs: 1500), !cached.entries.isEmpty {
                preZ = cached.entries
                Diagnostics.log("ZRESTORE", String(format: "preZ cached snapshot for target=#%u age=%.1fms gen=%llu n=%d", wid, cached.ageMs, cached.generation, preZ.count))
            } else {
                preZ = liveFullZOrderSnapshotForIntent()
                if !preZ.isEmpty {
                    let preZSummary = preZ.prefix(8).enumerated().map { "z\($0.0)=#\($0.1.wid) \($0.1.owner.prefix(10))" }.joined(separator: " | ")
                    Diagnostics.log("ZRESTORE", "preZ snapshot for target=#\(wid) (n=\(preZ.count)): \(preZSummary)")
                }
            }
            recentZOrderIntents.removeAll { $0.wid == wid }
            recentZOrderIntents.append(ZOrderIntent(
                wid: wid, pid: target.application.pid,
                timestamp: now, window: target, preZRanking: preZ))
            startZOrderEnforcement()
        }
    }

    static func armNativeFocusZOrderIntent(for target: Window, preZ: [PreZEntry]) {
        guard RuntimeFlags.zOrderFixesEnabled, let wid = target.cgWindowId else { return }
        let now = CFAbsoluteTimeGetCurrent()
        recentZOrderIntents.removeAll { now - $0.timestamp > 3.0 || $0.wid == wid }
        recentZOrderIntents.append(ZOrderIntent(wid: wid, pid: target.application.pid, timestamp: now, window: target, preZRanking: preZ))
        Diagnostics.log("ZENFORCE", "native intent target=#\(wid) preZ=\(preZ.count)")
        startZOrderEnforcement()
    }

    static func releaseZOrderEnforcementForUserClick(wid: CGWindowID, pid: pid_t, label: String) {
        guard let current = recentZOrderIntents.last, current.wid != wid else { return }
        Diagnostics.log("ZENFORCE", "released by user click: clicked=#\(wid) pid=\(pid) \(label.prefix(30)) target=#\(current.wid)")
        recentZOrderIntents.removeAll()
        zOrderEnforcementGeneration &+= 1
        zOrderEnforcementTimer?.cancel()
        zOrderEnforcementTimer = nil
    }

    static func noteSyntheticFocusClick() {
        syntheticFocusClickTimestamp = TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
        syntheticFocusClickIgnoreUntil = CFAbsoluteTimeGetCurrent() + 3.0
    }

    static func shouldIgnoreSyntheticFocusClick(eventTimestamp: TimeInterval) -> Bool {
        guard CFAbsoluteTimeGetCurrent() < syntheticFocusClickIgnoreUntil else { return false }
        return abs(eventTimestamp - syntheticFocusClickTimestamp) < 0.5
    }

    /// Poll actual z-order every 500ms for 5s after last focus target.
    /// If the most recent target isn't at z0 among app windows, re-raise.
    private static func startZOrderEnforcement() {
        guard RuntimeFlags.zOrderFixesEnabled else { return }
        zOrderEnforcementTimer?.cancel()
        zOrderEnforcementGeneration &+= 1
        let myGen = zOrderEnforcementGeneration
        Diagnostics.log("ZENFORCE", "starting timer gen=\(myGen), \(recentZOrderIntents.count) intents")
        // Early-phase pre-emptive checks. Two regimes of bounces observed:
        //   1. 2026-04-27 19:54:08: Parallels-adjacent windows bounce at
        //      ~+200ms and ~+400ms after focus (Coherence settling timer).
        //   2. 2026-05-05 02:02 profiler Run 3: when source is Parallels and
        //      target is Mac (focusMacOsWindowOverParallelsCoherence), the
        //      Parallels source's process briefly re-raises in the +10..50ms
        //      window before the SLPS+makeKey settles. Profiler caught it
        //      with checkpoints at 5/10/15/20/30/40/50ms.
        // Schedule densely from +5ms to cover both regimes. Each tick is
        // ~1 CGWindowListCopyWindowInfo on main + a possible CGSOrderWindow,
        // gated to do nothing when target is already z0 — so the no-op
        // case is cheap. Logs only fire under `trace` level.
        // TEMPORARY A/B revert to validate the fix actually matters:
        // if profiler bounces re-appear at ~10-25ms, the dense early ticks
        // are demonstrably the corrective intervention.
        let zenforceEarlyABMode = UserDefaults.standard.string(forKey: "zenforceEarlyABMode") ?? "fast"
        let earlyOffsetsMs: [Int] = (zenforceEarlyABMode == "slow")
            ? [30, 80, 150, 250, 350, 450]
            : [5, 12, 25, 50, 100, 200, 350]
        for ms in earlyOffsetsMs {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms)) {
                guard zOrderEnforcementGeneration == myGen else { return }
                guard !recentZOrderIntents.isEmpty else { return }
                enforceZOrder()
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Late-phase polling: regular 200ms cadence after the dense
        // early window. Each check is one CGWindowListCopyWindowInfo
        // + potential AX raise.
        timer.schedule(deadline: .now() + .milliseconds(550),
                       repeating: .milliseconds(200))
        timer.setEventHandler {
            guard zOrderEnforcementGeneration == myGen else { return }
            let now = CFAbsoluteTimeGetCurrent()
            recentZOrderIntents.removeAll { now - $0.timestamp > 3.0 }
            guard !recentZOrderIntents.isEmpty else {
                Diagnostics.log("ZENFORCE", "no intents left, stopping timer")
                zOrderEnforcementTimer?.cancel()
                zOrderEnforcementTimer = nil
                return
            }
            enforceZOrder()
        }
        timer.resume()
        zOrderEnforcementTimer = timer
        // Auto-stop after 3s (aligned with focus guard duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            guard zOrderEnforcementGeneration == myGen else { return }
            Diagnostics.log("ZENFORCE", "5s auto-stop gen=\(myGen)")
            zOrderEnforcementTimer?.cancel()
            zOrderEnforcementTimer = nil
        }
    }

    /// Check that the most recent target is at z0 in the actual window
    /// list. If not, use CGSOrderWindow to directly reorder it without
    /// process-level activation side effects.
    private static func enforceZOrder() {
        guard RuntimeFlags.zOrderFixesEnabled else { return }
        guard let mostRecent = recentZOrderIntents.last,
              let window = mostRecent.window else { return }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }
        let blocklist: Set<String> = [
            "Window Server", "Control Center", "Dock", "AltTab",
            "Notification Center", "SystemUIServer", "Spotlight",
            "Menubar", "Wallpaper", "CursorUIViewService",
            "LocalAuthenticationRemoteService",
        ]
        // First pass: find target's window level. Ignore any windows above
        // the target's level when computing its z-position — they're on a
        // higher compositor layer (screenshot previews at kCGMainMenuWindowLevel
        // Lv24, modal panels, etc.) that cannot be pushed under by any
        // API we have. Target-at-top-of-its-own-level counts as success.
        var targetLayer = 0
        for w in info {
            if let wid = w[kCGWindowNumber as String] as? Int,
               CGWindowID(wid) == mostRecent.wid {
                targetLayer = (w[kCGWindowLayer as String] as? Int) ?? 0
                break
            }
        }
        var targetZPos = -1
        var sameAppBlockerWid: CGWindowID? = nil
        var sameAppBlockerName: String = ""
        var z0Wid: CGWindowID? = nil
        var z0Owner: String = "?"
        var z0Name: String = ""
        var pos = 0
        var topWids = [(Int, String)]() // for logging
        for w in info {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            if blocklist.contains(owner) { continue }
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha < 0.1 { continue }
            if let bounds = w[kCGWindowBounds as String] as? [String: Any],
               let width = bounds["Width"] as? Double, width < 40 { continue }
            let layer = (w[kCGWindowLayer as String] as? Int) ?? 0
            if layer > targetLayer { continue } // unreachable overlay
            let wid = (w[kCGWindowNumber as String] as? Int) ?? 0
            let name = (w[kCGWindowName as String] as? String) ?? ""
            if pos == 0 {
                z0Wid = CGWindowID(wid)
                z0Owner = owner
                z0Name = name
            }
            if pos < 4 { topWids.append((wid, "\(owner.prefix(8)):\(name.prefix(15))")) }
            if CGWindowID(wid) == mostRecent.wid {
                targetZPos = pos
                break
            }
            // If a same-pid window above the target is NOT tracked in
            // Windows.list, it's a genuinely new window (dialog, popup,
            // confirmation) OR a stale Parallels/Teams sub-window. We
            // record the topmost such blocker so we can either skip
            // (after target was already at z0 — likely a fresh modal)
            // or pairwise-raise above it (before target ever reached
            // z0 — user explicitly asked for the target).
            let ownerPid = (w[kCGWindowOwnerPID as String] as? Int32) ?? 0
            let aboveWid = CGWindowID(wid)
            if ownerPid == mostRecent.pid {
                let isTracked = list.contains { $0.cgWindowId == aboveWid }
                if !isTracked && sameAppBlockerWid == nil {
                    sameAppBlockerWid = aboveWid
                    sameAppBlockerName = "\(owner):\(name.prefix(20))"
                    Diagnostics.log("ZENFORCE", "untracked same-app wid=\(aboveWid) \(owner):\(name.prefix(20)) above target — dialog?")
                }
            }
            pos += 1
        }
        let zSummary = topWids.enumerated().map { "z\($0.0)=#\($0.1.0) \($0.1.1)" }.joined(separator: " | ")
        Diagnostics.log("ZENFORCE", "target=\(mostRecent.wid) at z\(targetZPos) [\(zSummary)]")
        // ZALIGN: comprehensive per-tick alignment check the user asked for.
        // Captures all three signals (target, z0, AX-focused) live and logs
        // any divergence. Fires on every tick so we can see whether
        // interventions are actually correcting the state.
        logZAlignment(target: mostRecent.wid, z0Wid: z0Wid, z0Label: "\(z0Owner):\(z0Name.prefix(20))")
        diagnoseFrontmostMismatch(targetWid: mostRecent.wid, targetPid: mostRecent.pid, atZ0: targetZPos == 0)
        if targetZPos == 0 {
            if !mostRecent.wasEverAtZ0 {
                let intentIndex = recentZOrderIntents.count - 1
                recentZOrderIntents[intentIndex].wasEverAtZ0 = true
                recentZOrderIntents[intentIndex].raiseAttempts = 0
                // Target just reached z0 for the first time this session.
                // Some focus paths (`_SLPSSetFrontProcessWithOptions`,
                // process activation) inadvertently bring multiple
                // windows of the target's app above OTHER apps' windows
                // — visible as `[DIAG SAMEAPP]`. The user-expected
                // z-order is: target on top, all OTHER apps' windows
                // preserved below in their prior relative order, the
                // target's siblings staying where they were. Any
                // sibling that's now sandwiched ABOVE a non-target-app
                // window is a regression introduced by our intervention
                // → push it below the divider.
                restoreExpectedZOrderIfNeeded(intentIndex: intentIndex, force: true)
            } else {
                restoreExpectedZOrderIfNeeded(intentIndex: recentZOrderIntents.count - 1)
            }
        } else if targetZPos > 0 && sameAppBlockerWid != nil && mostRecent.wasEverAtZ0 {
            // Target was already at z0 once; an untracked same-app window
            // appeared on top AFTERWARDS — most likely a legitimate
            // dialog/sheet. Don't fight it.
            Diagnostics.log("ZENFORCE", "wid=\(mostRecent.wid) at z\(targetZPos) — same-app dialog above (target was at z0 prior); skipping")
        } else if targetZPos > 0 {
            guard mostRecent.raiseAttempts < ZOrderIntent.maxRaiseAttempts else {
                Diagnostics.log("ZENFORCE", "wid=\(mostRecent.wid) at z\(targetZPos), max \(ZOrderIntent.maxRaiseAttempts) attempts — stopping")
                recentZOrderIntents.removeAll()
                return
            }
            recentZOrderIntents[recentZOrderIntents.count - 1].raiseAttempts += 1
            let attempt = recentZOrderIntents[recentZOrderIntents.count - 1].raiseAttempts
            // Pairwise raise above the specific blocker first (when a
            // same-app window is sitting above the target). More precise
            // than `relativeTo: 0` and works in cases where a generic
            // .above-of-everything fails because of WindowServer's
            // per-process ordering rules.
            if let blocker = sameAppBlockerWid {
                let pwErr = CGSOrderWindow(CGS_CONNECTION, mostRecent.wid,
                                           CGSWindowOrderingMode.above.rawValue, blocker)
                Diagnostics.log("ZENFORCE", "INTERVENE pairwise CGSOrderWindow(wid=\(mostRecent.wid) above #\(blocker) \(sameAppBlockerName)) → \(pwErr == .success ? "OK" : "err=\(pwErr.rawValue)") attempt #\(attempt)")
            }
            let err = CGSOrderWindow(CGS_CONNECTION, mostRecent.wid,
                                     CGSWindowOrderingMode.above.rawValue, 0)
            if err == .success {
                Diagnostics.log("ZENFORCE", "INTERVENE CGSOrderWindow(wid=\(mostRecent.wid) above all) → OK fixed z\(targetZPos)→z0")
            } else {
                // For same-pid windows (e.g., multiple Outlook emails),
                // kAXRaiseAction doesn't work — Parallels ignores it.
                // Use setAttribute(kAXFocusedWindowAttribute) which TELLS
                // the app which window should be focused.
                // For same-pid Parallels windows, use makeKeyWindow
                // (synthetic HID event) which Parallels responds to even
                // after settling its internal z-order. AX raise alone
                // doesn't work for same-pid reordering.
                var psn = ProcessSerialNumber()
                GetProcessForPID(mostRecent.pid, &psn)
                // SLPS(.noWindows) brings the target's APP to frontmost
                // without changing z-order itself. Critical for cross-app
                // raises (e.g. Chrome steals front from OneNote during
                // guard window): AX raise alone can't push a backgrounded
                // app's window above the active app's — macOS refuses.
                // Process activation first, then makeKeyWindow + AX raise
                // as before.
                _SLPSSetFrontProcessWithOptions(&psn, mostRecent.wid, SLPSMode.noWindows.rawValue)
                window.makeKeyWindow(&psn)
                queueAxRecovery(for: window, wid: mostRecent.wid, pid: mostRecent.pid, attempt: attempt, generation: zOrderEnforcementGeneration)
                Diagnostics.log("ZENFORCE", "wid=\(mostRecent.wid) at z\(targetZPos), SLPS+makeKey queued AX recovery #\(attempt)/\(ZOrderIntent.maxRaiseAttempts)")
            }
        } else {
            Diagnostics.log("ZENFORCE", "wid=\(mostRecent.wid) not found in z-order (offscreen?)")
        }
    }

    private static func queueAxRecovery(for window: Window, wid: CGWindowID, pid: pid_t, attempt: Int, generation: UInt64) {
        guard !queuedAxRecoveryWids.contains(wid) else { return }
        queuedAxRecoveryWids.insert(wid)
        BackgroundWork.accessibilityCommandsQueue.addOperation { [weak window] in
            defer {
                DispatchQueue.main.async {
                    queuedAxRecoveryWids.remove(wid)
                }
            }
            let isCurrent = DispatchQueue.main.sync {
                zOrderEnforcementGeneration == generation && recentZOrderIntents.last?.wid == wid
            }
            guard isCurrent, let window else { return }
            if let appAx = window.application.axUiElement, let selfAx = window.axUiElement {
                try? appAx.setAttribute(kAXFocusedWindowAttribute, selfAx)
                if window.application.isParallelsCoherence {
                    let fmErr = AXUIElementSetAttributeValue(appAx, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                    Diagnostics.log("FRONTMOSTSET", "ZENFORCE recovery kAXFrontmost=true pid=\(pid) wid=\(wid) → \(fmErr == .success ? "OK" : "err=\(fmErr.rawValue)")")
                }
            }
            try? window.axUiElement?.performAction(kAXRaiseAction as String)
            Diagnostics.log("ZENFORCE", "AX recovery done wid=\(wid) attempt #\(attempt)")
        }
    }

    /// Restore the *full* user-expected z-order after a focus call.
    /// Computes expected = [target] + (preZRanking minus target,
    /// preserving prior relative order). Then walks expected top→down
    /// and pairwise-CGSOrderWindow's each entry to its expected slot.
    /// If WindowServer rejects those cross-process moves, fall back to
    /// AX-raising the prior non-target app windows, then re-raise the
    /// selected target. That demotes same-app siblings without reordering
    /// every window in a large process like Terminal.
    ///
    /// Runs when the target first reaches z0, then re-checks for a few
    /// bounded guard ticks. That covers delayed app-level sibling raises
    /// without fighting natural app-driven z-order changes indefinitely.
    ///
    /// Skips windows that disappeared between snapshot and now, and
    /// windows that newly appeared (not in the snapshot — could be
    /// legitimate notifications, sheets, etc).
    private static func restoreExpectedZOrderIfNeeded(intentIndex: Int, force: Bool = false) {
        guard recentZOrderIntents.indices.contains(intentIndex) else { return }
        let intent = recentZOrderIntents[intentIndex]
        let now = CFAbsoluteTimeGetCurrent()
        guard force || now - intent.lastExpectedRestoreAt > 0.25 else { return }
        guard force || intent.expectedRestoreAttempts < ZOrderIntent.maxExpectedRestoreAttempts else { return }
        recentZOrderIntents[intentIndex].lastExpectedRestoreAt = now
        if restoreExpectedZOrder(targetWid: intent.wid, targetPid: intent.pid, preZ: intent.preZRanking) {
            recentZOrderIntents[intentIndex].expectedRestoreAttempts += 1
        }
    }

    @discardableResult
    private static func restoreExpectedZOrder(targetWid: CGWindowID, targetPid: pid_t, preZ: [PreZEntry]) -> Bool {
        guard !preZ.isEmpty else {
            Diagnostics.log("ZRESTORE", "no preZ snapshot for target=#\(targetWid); skipping")
            return false
        }
        // Build expected order: [target] + (preZ minus target)
        var expected: [PreZEntry] = []
        if !preZ.contains(where: { $0.wid == targetWid }) {
            // Target wasn't in the prior top-N — push it onto expected
            // anyway. Owner is best-effort; we don't strictly need it
            // for ordering decisions.
            expected.append(PreZEntry(wid: targetWid, pid: targetPid, owner: "target"))
        } else {
            expected.append(preZ.first { $0.wid == targetWid }!)
        }
        expected.append(contentsOf: preZ.filter { $0.wid != targetWid })
        // Capture current actual order (just the wids in z-order).
        let actual = Self.captureTopZRanking()
        let actualWids = actual.map { $0.wid }
        // Pre-summary line so we can compare expected vs actual at a
        // glance even before any corrections fire.
        let expSummary = expected.prefix(8).enumerated().map { "z\($0.0)=#\($0.1.wid) \($0.1.owner.prefix(10))" }.joined(separator: " | ")
        let actSummary = actual.prefix(8).enumerated().map { "z\($0.0)=#\($0.1.wid) \($0.1.owner.prefix(10))" }.joined(separator: " | ")
        Diagnostics.log("ZRESTORE", "compare target=#\(targetWid)\n  expected: \(expSummary)\n  actual:   \(actSummary)")
        // Walk expected[1...] top→down, ensure each is just below its
        // predecessor. expected[0] (target) is already pinned at z0 by
        // ZENFORCE — don't touch it here, the relativeTo-0 .above call
        // is what ZENFORCE already does.
        var corrections = 0
        var failures = 0
        var prevWid: CGWindowID = targetWid
        for entry in expected.dropFirst() {
            // Skip if this window is no longer visible.
            guard actualWids.contains(entry.wid) else { continue }
            // Check if it's already in the right relative position
            // (immediately below prevWid in actual). If so, no-op.
            if let actIdx = actualWids.firstIndex(of: entry.wid),
               let prevIdx = actualWids.firstIndex(of: prevWid),
               actIdx == prevIdx + 1 {
                prevWid = entry.wid
                continue
            }
            let err = CGSOrderWindow(CGS_CONNECTION, entry.wid,
                                     CGSWindowOrderingMode.below.rawValue, prevWid)
            Diagnostics.log("ZRESTORE", "place #\(entry.wid) \(entry.owner.prefix(15)) below #\(prevWid) → \(err == .success ? "OK" : "err=\(err.rawValue)")")
            corrections += 1
            if err != .success { failures += 1 }
            prevWid = entry.wid
        }
        if corrections == 0 {
            Diagnostics.log("ZRESTORE", "no corrections needed (z-order matches expected) for target=#\(targetWid)")
        } else {
            Diagnostics.log("ZRESTORE", "applied \(corrections) corrections for target=#\(targetWid)")
        }
        if failures > 0 {
            Diagnostics.log("ZRESTORE", "CGS failed for \(failures) corrections; skipping AX full-stack restore for target=#\(targetWid)")
        }
        return corrections > 0
    }

    /// Per-tick alignment diagnostic. Captures the three signals the
    /// user perceives misalignment between:
    ///   - target: what AltTab was asked to focus
    ///   - z0:     what's actually visually on top (CGWindowList)
    ///   - axFoc:  what AX kAXFocusedWindow on the frontmost app reports
    /// Logs `[DIAG ZALIGN]` every tick so we can see the drift and
    /// whether interventions correct it. To avoid log spam, dedupes
    /// consecutive identical alignment states (same target/z0/axFoc).
    private static var lastZAlignSignature: String = ""
    private static func logZAlignment(target: CGWindowID, z0Wid: CGWindowID?, z0Label: String) {
        guard Diagnostics.shouldLog("ZALIGN") else { return }
        let nsApp = NSWorkspace.shared.frontmostApplication
        let frontPid = nsApp?.processIdentifier
        let frontApp = nsApp?.localizedName ?? "?"
        var axFocusedWid: CGWindowID? = nil
        var axFocusedTitle: String = "?"
        if let pid = frontPid {
            let appRef = AXUIElementCreateApplication(pid)
            var focused: AnyObject?
            if AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focused) == .success,
               let winRef = focused {
                var w: CGWindowID = 0
                if _AXUIElementGetWindow(winRef as! AXUIElement, &w) == .success {
                    axFocusedWid = w
                }
                var titleVal: AnyObject?
                if AXUIElementCopyAttributeValue(winRef as! AXUIElement, kAXTitleAttribute as CFString, &titleVal) == .success,
                   let t = titleVal as? String {
                    axFocusedTitle = String(t.prefix(20))
                }
            }
        }
        let zMatch = (z0Wid == target)
        let axMatch = (axFocusedWid == target)
        let signature = "\(target)|\(z0Wid ?? 0)|\(axFocusedWid ?? 0)"
        if signature == lastZAlignSignature { return }
        lastZAlignSignature = signature
        Diagnostics.log("ZALIGN",
            "target=#\(target) z0=#\(z0Wid ?? 0)(\(z0Label)) axFoc=#\(axFocusedWid ?? 0)(\(frontApp):\(axFocusedTitle)) | z0Match=\(zMatch) axMatch=\(axMatch)\(zMatch && axMatch ? " ✓ALIGNED" : "")")
    }

    /// Detect AND repair divergence between macOS z-order (window in front)
    /// and NSWorkspace.frontmostApplication (app receiving keyboard input).
    /// Phantom activations (Safari/system events that grab "front app"
    /// without changing z-order) leave the user looking at OneNote but
    /// typing into Safari. When detected, push the target's pid back to
    /// frontmost via SLPS(.noWindows) — process-only activation, no
    /// z-order change, since z-order is already correct.
    /// Only fires while ZENFORCE is active (poll-driven, 200ms cadence).
    private static var lastFrontMismatchLogged: pid_t? = nil
    private static var lastFrontRestoreAt: CFAbsoluteTime = 0
    private static func diagnoseFrontmostMismatch(targetWid: CGWindowID, targetPid: pid_t, atZ0: Bool) {
        guard atZ0 else { lastFrontMismatchLogged = nil; return }
        let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        guard frontPid != targetPid else {
            if lastFrontMismatchLogged != nil {
                Diagnostics.log("FRONT_MISMATCH", "resolved: target wid=\(targetWid) pid=\(targetPid) now matches frontmostApplication")
                lastFrontMismatchLogged = nil
            }
            return
        }
        let frontBundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        if lastFrontMismatchLogged != frontPid {
            lastFrontMismatchLogged = frontPid
            Diagnostics.log("FRONT_MISMATCH", "target wid=\(targetWid) at z0 (pid:\(targetPid)) but frontmostApplication pid=\(frontPid) (\(frontBundle.suffix(40))) — restoring")
        }
        restoreFrontmostToTarget(targetWid: targetWid, targetPid: targetPid, frontPid: frontPid)
    }

    /// Re-issue a process-level activation for the target's pid using
    /// SLPS(.noWindows). Bounded to one attempt per 400ms by default
    /// (poll-driven callers); `bypassThrottle` is for one-shot event-
    /// driven callers (e.g. click-misroute recovery) that need to fire
    /// immediately and don't repeat on their own.
    static func restoreFrontmostToTarget(targetWid: CGWindowID, targetPid: pid_t, frontPid: pid_t, source: String = "FRONT_MISMATCH", bypassThrottle: Bool = false) {
        guard RuntimeFlags.zOrderFixesEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if !bypassThrottle {
            guard now - lastFrontRestoreAt > 0.4 else { return }
        }
        lastFrontRestoreAt = now
        guard let target = list.first(where: { $0.cgWindowId == targetWid }) else { return }
        var psn = ProcessSerialNumber()
        GetProcessForPID(targetPid, &psn)
        _SLPSSetFrontProcessWithOptions(&psn, targetWid, SLPSMode.noWindows.rawValue)
        target.makeKeyWindow(&psn)
        Diagnostics.log(source, "restore attempt: SLPS(noWin)+makeKey(pid=\(targetPid), wid=\(targetWid)) — was frontmostPid=\(frontPid)")
    }

    /// Restore the correct z-order after a Parallels window close. macOS
    /// raises a random same-process window; we override by raising the top
    /// windows from our recency list in reverse order (so position 0 ends
    /// up on top). Query actual z-order first to only raise windows that
    /// are out of position.
    static func restoreZOrderFromRecency() {
        guard RuntimeFlags.zOrderFixesEnabled else { return }
        let topWindows = list
            .sorted { $0.lastFocusOrder < $1.lastFocusOrder }
            .prefix(5)
            .compactMap { w -> (Window, CGWindowID)? in
                guard let wid = w.cgWindowId else { return nil }
                return (w, wid)
            }
        guard !topWindows.isEmpty else { return }

        // Query actual z-order to find what's out of place
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let blocklist: Set<String> = [
            "Window Server", "Control Center", "Dock", "AltTab",
            "Notification Center", "SystemUIServer", "Spotlight",
            "Menubar", "Wallpaper", "CursorUIViewService",
            "LocalAuthenticationRemoteService",
        ]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }
        var actualZOrder = [CGWindowID]()
        for w in info {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            if blocklist.contains(owner) { continue }
            let alpha = (w[kCGWindowAlpha as String] as? Double) ?? 1.0
            if alpha < 0.1 { continue }
            if let bounds = w[kCGWindowBounds as String] as? [String: Any],
               let width = bounds["Width"] as? Double, width < 40 { continue }
            let wid = CGWindowID((w[kCGWindowNumber as String] as? Int) ?? 0)
            actualZOrder.append(wid)
        }

        // Raise top recency windows in REVERSE order so #0 ends up on top.
        // Only raise if the window is out of position (lower in z than expected).
        let topWid = topWindows[0].1
        let topZPos = actualZOrder.firstIndex(of: topWid) ?? Int.max
        if topZPos == 0 {
            Diagnostics.log("ZRESTORE", "top window wid=\(topWid) already at z0, no restore needed")
            return
        }

        Diagnostics.log("ZRESTORE", "restoring z-order: top recency wid=\(topWid) at z\(topZPos)")

        // Try CGSOrderWindow to set exact z-order. Place each window
        // above the one that should be below it, working from bottom up.
        // This builds the correct stack: position 2 at bottom, 1 above it, 0 on top.
        var lastPlacedWid: CGWindowID = 0
        var cgsWorked = false
        for (_, wid) in topWindows.reversed() {
            guard actualZOrder.contains(wid) else { continue }
            if lastPlacedWid == 0 {
                // First window — place at top of z-order
                let err = CGSOrderWindow(CGS_CONNECTION, wid, CGSWindowOrderingMode.above.rawValue, 0)
                Diagnostics.log("ZRESTORE", "CGSOrderWindow(wid=\(wid), above, 0) → \(err.rawValue)")
                if err == .success { cgsWorked = true }
            } else {
                // Place above the previously placed window
                let err = CGSOrderWindow(CGS_CONNECTION, wid, CGSWindowOrderingMode.above.rawValue, lastPlacedWid)
                Diagnostics.log("ZRESTORE", "CGSOrderWindow(wid=\(wid), above, \(lastPlacedWid)) → \(err.rawValue)")
                if err == .success { cgsWorked = true }
            }
            lastPlacedWid = wid
        }

        // If CGSOrderWindow failed (err 1000), fall back to AX raise
        // in reverse order (position 2, then 1, then 0).
        if !cgsWorked {
            Diagnostics.log("ZRESTORE", "CGSOrderWindow failed, falling back to AX raise")
            for (window, wid) in topWindows.reversed() {
                guard actualZOrder.contains(wid) else { continue }
                try? window.axUiElement?.performAction(kAXRaiseAction as String)
            }
        }

        // Activate the top window SYNCHRONOUSLY via SLPS before Parallels
        // can raise its own window. Also AX raise immediately.
        let (topWindow, _) = topWindows[0]
        var psn = ProcessSerialNumber()
        GetProcessForPID(topWindow.application.pid, &psn)
        if let wid = topWindow.cgWindowId {
            _SLPSSetFrontProcessWithOptions(&psn, wid, SLPSMode.userGenerated.rawValue)
            topWindow.makeKeyWindow(&psn)
            try? topWindow.axUiElement?.focusWindow()
            Diagnostics.log("ZRESTORE", "SLPS + makeKeyWindow + AX raise for top wid=\(wid) \(topWindow.debugId ?? "?")")
        }
    }

    /// Clear the guard at the start of each new focus() call so a 2-second
    /// guard left over from a prior Parallels transition can't silently
    /// suppress legitimate focus events from a subsequent macOS→macOS
    /// switch. The Parallels focus paths re-arm the guard themselves
    /// when they need it; the standard SLPS path doesn't — leaving it
    /// cleared is the correct default.
    ///
    /// ALSO bumps `parallelsTransitionGeneration` so any pending delayed
    /// snapshot-restore block from a prior Parallels transition becomes
    /// stale and is skipped. Without this, a Par→A restore scheduled at
    /// t+500ms would fire after the user has mac→B-switched, restoring
    /// the pre-Par state and demoting B out of position 0.
    static func clearAltTabFocusGuard() {
        altTabFocusTarget = nil
        altTabFocusTargetUntil = 0
        parallelsTransitionGeneration &+= 1
        // Stop z-order enforcement — a new focus() call means the user
        // switched to a different window; enforcing the old target's
        // z-position would fight the user's intent.
        recentZOrderIntents.removeAll()
        zOrderEnforcementGeneration &+= 1
        zOrderEnforcementTimer?.cancel()
        zOrderEnforcementTimer = nil
    }

    static func shouldSuppressFocusOrderUpdate(for window: Window) -> Bool {
        guard CFAbsoluteTimeGetCurrent() < altTabFocusTargetUntil,
              let target = altTabFocusTarget else { return false }
        return window !== target
    }

    /// Same guard semantics as `shouldSuppressFocusOrderUpdate` but
    /// checks app-level (for `kAXApplicationActivatedNotification`
    /// events). Returns true if a Parallels-transition guard is armed
    /// and the activating app isn't the target's app.
    ///
    /// EVENT-DRIVEN COUNTER-RAISE: when this returns true, we also
    /// schedule an immediate re-raise of the target. This way,
    /// Parallels' timer-driven self-activation (which fires ~1s after
    /// our focus) is countered the moment it's detected — no timing
    /// guesswork needed. The re-raise runs on the background AX queue
    /// so AX IPC can't freeze main thread.
    static var counterRaiseCount = 0
    static let maxCounterRaises = 3
    /// Timestamp of the last global mouse click, used to distinguish
    /// user-initiated window activations from Parallels' automatic
    /// re-activation. Updated by the global event monitor installed
    /// at startup.
    static var lastMouseClickTime: CFAbsoluteTime = 0
    static var lastMouseClickWid: CGWindowID = 0
    static var lastMouseClickPid: pid_t = 0
    static var lastMouseClickOwner: String = ""

    static func shouldSuppressApplicationActivation(for app: Application) -> Bool {
        guard CFAbsoluteTimeGetCurrent() < altTabFocusTargetUntil,
              let target = altTabFocusTarget else { return false }
        guard target.application.pid != app.pid else { return false }
        // If a mouse click happened recently, this is a user-initiated
        // activation — allow it through and clear the guard so subsequent
        // AX events from the clicked window also pass.
        let timeSinceClick = CFAbsoluteTimeGetCurrent() - lastMouseClickTime
        if timeSinceClick < 0.3 {
            Diagnostics.log("CLICK", "mouse click detected \(Int(timeSinceClick * 1000))ms ago, allowing activation of pid=\(app.pid) \(app.bundleIdentifier ?? "?"), clearing guard")
            clearAltTabFocusGuard()
            return false
        }
        // Suppress ALL non-target activations during the guard, not just
        // Parallels. During rapid double alt-tabs, the FIRST target's
        // stale AXEVENT can arrive after we've switched to the second
        // target, corrupting frontmostPid. User clicks are already
        // handled above via the mouse click check.
        // Counter-raise only for Parallels (they actively fight back).
        if app.isParallelsCoherence, counterRaiseCount < maxCounterRaises {
            counterRaiseCount += 1
            Diagnostics.log("COUNTER", "Parallels stole front (attempt \(counterRaiseCount)/\(maxCounterRaises)), counter-raising \(target.debugId ?? "?")")
            // AX raise only — no activate() which raises ALL app windows.
            // ZENFORCE also enforces z-order independently.
            BackgroundWork.accessibilityCommandsQueue.addOperation { [weak target] in
                guard let target else { return }
                try? target.axUiElement?.focusWindow()
                Diagnostics.log("API", "COUNTER AX focusWindow done")
            }
        }
        return true
    }
    private static var lastWindowActivityType = WindowActivityType.none
    static var searchQuery = ""
    private static var shouldSelectBestMatchOnSearchChange = false
    private static var shouldRestoreDefaultSelectionOnSearchClear = false

    static func shouldDisplay(_ window: Window) -> Bool {
        window.shouldShowTheUser && Search.matches(window, query: searchQuery)
    }

    static func updateSearchQuery(_ query: String) {
        let previousTrimmedQuery = Search.normalizedQuery(searchQuery)
        let newTrimmedQuery = Search.normalizedQuery(query)
        searchQuery = query
        guard App.appIsBeingUsed else {
            shouldSelectBestMatchOnSearchChange = false
            shouldRestoreDefaultSelectionOnSearchClear = false
            sort()
            return
        }
        if previousTrimmedQuery != newTrimmedQuery {
            if newTrimmedQuery.isEmpty {
                shouldRestoreDefaultSelectionOnSearchClear = !previousTrimmedQuery.isEmpty
                shouldSelectBestMatchOnSearchChange = false
            } else {
                shouldSelectBestMatchOnSearchChange = true
                shouldRestoreDefaultSelectionOnSearchClear = false
                hoveredWindowIndex = nil
            }
        }
        sort()
    }

    static func updateIsFullscreenOnCurrentSpace() {
        let windowsOnCurrentSpace = list.filter { !$0.isWindowlessApp }
        for window in windowsOnCurrentSpace {
            guard let wid = window.cgWindowId, let axUiElement = window.axUiElement else { continue }
            AXCallScheduler.shared.schedule(key: "wid-\(wid)", context: window.debugId, pid: window.application.pid) { [weak window] in
                guard let window else { return }
                // we reuse existing code, to update .isFullscreen, as if there was a kAXWindowResizedNotification
                try AccessibilityEvents.handleEventWindow(kAXWindowResizedNotification, wid, window.application.pid, axUiElement)
            }
        }
    }

    private static func compareByAppNameThenWindowTitle(_ w1: Window, _ w2: Window) -> ComparisonResult {
        let order = w1.application.localizedName.localizedStandardCompare(w2.application.localizedName)
        if order == .orderedSame {
            return w1.title.localizedStandardCompare(w2.title)
        }
        return order
    }

    static func voiceOverWindow(_ windowIndex: Int = selectedWindowIndex) {
        guard App.appIsBeingUsed && TilesPanel.shared.isKeyWindow else { return }
        if TilesView.isSearchEditing { return }
        // it seems that sometimes makeFirstResponder is called before the view is visible
        // and it creates a delay in showing the main window; calling it with some delay seems to work around this
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) {
            if TilesView.isSearchEditing { return }
            let window = TilesView.recycledViews[windowIndex]
            if window.window_ != nil && window.window != nil {
                TilesPanel.shared.makeFirstResponder(window)
            }
        }
    }

    static func previewSelectedWindowIfNeeded() {
        if App.appIsBeingUsed && ScreenRecordingPermission.status == .granted
               && Preferences.previewSelectedWindow && !Preferences.onlyShowApplications()
               && TilesPanel.shared.isKeyWindow,
           let window = selectedWindow(),
           let id = window.cgWindowId,
           let thumbnail = window.thumbnail,
           let position = window.position,
           let size = window.size {
            PreviewPanel.show(id, thumbnail, position, size)
        } else {
            PreviewPanel.shared.orderOut(nil)
        }
    }

    static func updatesBeforeShowing() -> Bool {
        let startedAt = CFAbsoluteTimeGetCurrent()
        if MissionControl.state() == .showAllWindows || MissionControl.state() == .showFrontWindows { return false }
        if list.isEmpty { return true }
        refreshSpacesBeforeShowingIfNeeded()
        let afterSpacesAt = CFAbsoluteTimeGetCurrent()
        // Parallels Coherence rewrites the guest window title on page/tab
        // navigation. Empirically (logs 2026-04-27): both
        // kAXTitleChangedNotification AND CGWindowListCopyWindowInfo's
        // kCGWindowName return the STALE title for non-front Parallels
        // windows. Only a direct per-window kAXTitleAttribute query
        // returns the current guest-side title (proven by [DIAG FRONT]'s
        // sysFocus probe at Logger.swift returning live titles for
        // wid=18882 while the cached title stayed "Trading - April 2026"
        // for hours).
        let spacesPreference = Preferences.spacesToShow[App.shortcutIndex]
        let screensPreference = Preferences.screensToShow[App.shortcutIndex]
        let forceRefreshWindowSpaces = UserDefaults.standard.bool(forKey: "forceRefreshWindowSpacesBeforeShowing")
        let refreshVisibleWindowIds = UserDefaults.standard.bool(forKey: "refreshVisibleWindowIdsBeforeShowing")
        let visibleWindowIds = spacesPreference == .all || !refreshVisibleWindowIds ? nil : Set(Spaces.windowsInSpaces(Spaces.visibleSpaces))
        let shouldRefreshWindowSpaces = screensPreference == .showingAltTab || forceRefreshWindowSpaces
        let shouldRefreshParallelsTitles = shouldRefreshParallelsTitlesBeforeShowing()
        let spaceRefreshMode = shouldRefreshWindowSpaces ? "per-window" : (visibleWindowIds == nil ? "cached" : "bulk-visible")
        var parWindowsSeen = 0
        var parWindowsQueried = 0
        var parTitlesObtained = 0
        for window in list {
            if shouldRefreshWindowSpaces {
                window.updateSpacesAndScreen()
            }
            if window.isParallelsCoherenceWindow {
                parWindowsSeen += 1
            }
            if shouldRefreshParallelsTitles, window.isParallelsCoherenceWindow, let axElement = window.axUiElement {
                parWindowsQueried += 1
                var titleValue: AnyObject?
                let axStatus = AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &titleValue)
                if axStatus == .success, let liveTitle = titleValue as? String, !liveTitle.isEmpty {
                    parTitlesObtained += 1
                    window.refreshTitleIfChanged(liveTitle)  // logs [DIAG TITLE] if changed
                } else if let wid = window.cgWindowId {
                    // Surfaces "AX query failed for non-front window" — tells us
                    // whether AX itself is stale on background Parallels windows
                    // (in which case we have no live source at all).
                    Diagnostics.log("AXTITLE", "wid=\(wid) cached='\(window.title ?? "")' AX failed: status=\(axStatus.rawValue)")
                }
            }
            refreshIfWindowShouldBeShownToTheUser(window, visibleWindowIds)
        }
        let afterWindowsAt = CFAbsoluteTimeGetCurrent()
        if parWindowsQueried > 0 {
            Diagnostics.log("REFRESH", "panel build: parallels_windows=\(parWindowsQueried) ax_titles_obtained=\(parTitlesObtained) space_refresh=\(spaceRefreshMode)")
        } else if parWindowsSeen > 0 {
            Diagnostics.log("REFRESH", "panel build: parallels_windows=\(parWindowsSeen) ax_titles_skipped=mac-fast-path space_refresh=\(spaceRefreshMode)")
        }
        refreshWhichWindowsToShowTheUser()
        sort()
        let afterSortAt = CFAbsoluteTimeGetCurrent()
        Diagnostics.log("REFRESH", String(format: "updatesBeforeShowing: total=%.1fms spaces=%.1fms windows=%.1fms sort=%.1fms count=%d", (afterSortAt - startedAt) * 1000, (afterSpacesAt - startedAt) * 1000, (afterWindowsAt - afterSpacesAt) * 1000, (afterSortAt - afterWindowsAt) * 1000, list.count))
        return true
    }

    private static func refreshSpacesBeforeShowingIfNeeded() {
        if UserDefaults.standard.bool(forKey: "forceRefreshWindowSpacesBeforeShowing") {
            Spaces.refresh()
            return
        }
        let intervalMs = UserDefaults.standard.integer(forKey: "refreshSpacesBeforeShowingIntervalMs")
        guard intervalMs > 0 else { return }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - Spaces.lastRefreshAt) * 1000
        if elapsedMs > Double(intervalMs) {
            Spaces.refresh()
        }
    }

    private static func shouldRefreshParallelsTitlesBeforeShowing() -> Bool {
        if UserDefaults.standard.bool(forKey: "alwaysRefreshCoherenceTitlesBeforeShowing") { return true }
        if let sourcePid = App.sessionSourcePid,
           Applications.list.first(where: { $0.pid == sourcePid })?.isParallelsCoherence == true {
            return true
        }
        if selectedWindow()?.application.isParallelsCoherence == true {
            return true
        }
        return list
            .sorted { $0.lastFocusOrder < $1.lastFocusOrder }
            .dropFirst()
            .first?
            .application
            .isParallelsCoherence == true
    }

    // dispatch screenshot requests off the main-thread, then wait for completion
    static func refreshThumbnailsAsync(_ windows: [Window], _ source: RefreshCausedBy, windowRemoved: Bool = false) {
        guard RuntimeFlags.thumbnailCaptureEnabled
               && (!windows.isEmpty || windowRemoved) && ScreenRecordingPermission.status == .granted
               && !Preferences.onlyShowApplications()
               && (!Appearance.hideThumbnails || Preferences.previewSelectedWindow)
               && (Preferences.captureWindowsInBackground || App.appIsBeingUsed) else { return }
        let skipCoherencePreviews = UserDefaults.standard.bool(forKey: "disableCoherencePreviews")
        // Background captures of Parallels Coherence windows hit
        // CGSHWCaptureWindowList → WindowServer compositor → guest pixel
        // blit, and on macOS 15 visibly flicker the mouse cursor when fired
        // at high rates. OneNote rewrites its title on each keystroke,
        // which fans out to a capture every ~200ms while the user types.
        // Skip Coherence captures on background AX events; the panel-open
        // path (.refreshOnlyThumbnailsAfterShowUi) still captures fresh.
        let skipCoherenceForBackground = source == .refreshUiAfterExternalEvent && !App.appIsBeingUsed
        var eligibleWindows = [Window]()
        for window in windows {
            if !window.isWindowlessApp, let cgWindowId = window.cgWindowId, cgWindowId != CGWindowID(bitPattern: -1) {
                if (skipCoherencePreviews || skipCoherenceForBackground) && window.application.isParallelsCoherence { continue }
                eligibleWindows.append(window)
            }
        }
        guard (!eligibleWindows.isEmpty || windowRemoved) else { return }
        // Split eligible windows by capture method.
        // ScreenCaptureKit (macOS 14+) sees the macOS-side view of each
        // window. For Parallels Coherence windows, that view is the
        // empty shim NSWindow that Parallels uses — the guest-rendered
        // pixel content is composited via a separate channel SCK can't
        // observe, so SCK returns blank/wrong thumbnails.
        // The private API CGSHWCaptureWindowList CAN capture this
        // content because it goes through the WindowServer's HW
        // capture path that includes Parallels' compositor output.
        // Net: use SCK for native macOS windows, fall back to the
        // private API only for Parallels Coherence windows.
        let parallelsWindows = eligibleWindows.filter { $0.isParallelsCoherenceWindow }
        let nativeWindows = eligibleWindows.filter { !$0.isParallelsCoherenceWindow }
        let useSck = {
            if #available(macOS 14.0, *) {
                // mitigate macOS 15 bugs with ScreenCapture Kit (see https://github.com/lwouis/alt-tab-macos/issues/5190)
                return ProcessInfo.processInfo.operatingSystemVersion.majorVersion != 15
            }
            return false
        }()
        if !nativeWindows.isEmpty {
            if useSck, #available(macOS 14.0, *) {
                WindowCaptureScreenshots.oneTimeScreenshots(nativeWindows, source)
            } else {
                WindowCaptureScreenshotsPrivateApi.oneTimeScreenshots(nativeWindows, source)
            }
        }
        if !parallelsWindows.isEmpty {
            // Always private API for Parallels Coherence; SCK doesn't
            // see the guest-rendered pixel content.
            WindowCaptureScreenshotsPrivateApi.oneTimeScreenshots(parallelsWindows, source)
        }
    }

    static func invalidateThumbnails(_ windows: [Window] = list) {
        windows.forEach { $0.invalidateThumbnail() }
    }

    static func refreshWhichWindowsToShowTheUser() {
        if Preferences.onlyShowApplications() {
            // Group windows by application and select the optimal main window
            let windowsGroupedByApp = Dictionary(grouping: list) { $0.application.pid }
            windowsGroupedByApp.forEach { (app, windows) in
                if windows.count > 1, let mainWindow = findMainWindow(windows) {
                    windows.forEach { window in
                        if window.cgWindowId != mainWindow.cgWindowId {
                            window.shouldShowTheUser = false
                        }
                    }
                }
            }
        }
    }

    private static func shouldHideWindow(_ window: Window, _ entry: ExceptionEntry) -> Bool {
        switch entry.hide {
        case .none:
            return false
        case .always:
            return true
        case .whenNoOpenWindow:
            return window.isWindowlessApp
        case .windowTitleContains:
            guard let titleFilter = entry.windowTitleContains, !titleFilter.isEmpty else {
                return false
            }
            return window.title.contains(titleFilter)
        }
    }

    private static func refreshIfWindowShouldBeShownToTheUser(_ window: Window, _ visibleWindowIds: Set<CGWindowID>? = nil) {
        let isInVisibleSpace = isWindowInVisibleSpace(window, visibleWindowIds)
        window.shouldShowTheUser =
            !(window.application.bundleIdentifier.flatMap { id in
                Preferences.exceptions.contains {
                    id.hasPrefix($0.bundleIdentifier) && shouldHideWindow(window, $0)
                }
            } ?? false) &&
            !(Preferences.appsToShow[App.shortcutIndex] == .active && window.application.pid != Applications.frontmostPid) &&
            !(Preferences.appsToShow[App.shortcutIndex] == .nonActive && window.application.pid == Applications.frontmostPid) &&
            !(!(Preferences.showHiddenWindows[App.shortcutIndex] != .hide) && window.isHidden) &&
            ((Preferences.showWindowlessApps[App.shortcutIndex] != .hide && window.isWindowlessApp) ||
                !window.isWindowlessApp &&
                !(!(Preferences.showFullscreenWindows[App.shortcutIndex] != .hide) && window.isFullscreen) &&
                !(!(Preferences.showMinimizedWindows[App.shortcutIndex] != .hide) && window.isMinimized) &&
                !(Preferences.spacesToShow[App.shortcutIndex] == .visible && !isInVisibleSpace) &&
                !(Preferences.spacesToShow[App.shortcutIndex] == .nonVisible && isInVisibleSpace) &&
                !(Preferences.screensToShow[App.shortcutIndex] == .showingAltTab && !window.isOnScreen(NSScreen.preferred)) &&
                (Preferences.showTabsAsWindows || !window.isTabbed))
    }

    private static func isWindowInVisibleSpace(_ window: Window, _ visibleWindowIds: Set<CGWindowID>?) -> Bool {
        if let visibleWindowIds {
            if let wid = window.cgWindowId, visibleWindowIds.contains(wid) { return true }
            if let activeTabWid = TabGroup.activeTabSibling(of: window)?.cgWindowId {
                return visibleWindowIds.contains(activeTabWid)
            }
            return false
        }
        return Spaces.visibleSpaces.contains { visibleSpace in
            window.spaceIds.contains { $0 == visibleSpace }
        }
    }

    /// Selects the most appropriate main window from a given list of windows.
    ///
    /// The selection criteria are as follows:
    /// 1. Prefer the focused window if it exists.
    /// 2. Prefer the main window of the application if the focused window is not found.
    ///
    /// - Parameter windows: An array of `Window` objects to select from.
    /// - Returns: The most appropriate `Window` object based on the selection criteria, or `nil` if the array is empty.
    static func findMainWindow(_ windows: [Window]) -> Window? {
        let sortedWindows = windows.sorted { (window1, window2) -> Bool in
            // Prefer the focus window
            if window1.application.focusedWindow?.cgWindowId == window1.cgWindowId {
                return true
            } else if window2.application.focusedWindow?.cgWindowId == window2.cgWindowId {
                return false
            }
            // Prefer the main window
            if window1.isAppMainWindow() && !window2.isAppMainWindow() {
                return true
            } else if !window1.isAppMainWindow() && window2.isAppMainWindow() {
                return false
            }
            return true
        }
        return sortedWindows.first { $0.shouldShowTheUser }
    }

    /// selectedWindowIndex methods
    //////////////////////////////

    static func selectedWindow() -> Window? {
        guard list.count > selectedWindowIndex else { return nil }
        let window = list[selectedWindowIndex]
        return shouldDisplay(window) ? window : nil
    }

    static func setInitialSelectedAndHoveredWindowIndex() {
        let oldIndex = selectedWindowIndex
        selectedWindowIndex = 0
        selectedWindowTarget = nil
        TilesView.highlight(oldIndex)
        if let oldIndex = hoveredWindowIndex {
            hoveredWindowIndex = nil
            TilesView.highlight(oldIndex)
        }
        if Applications.frontmostPid != nil,
           Preferences.windowOrder[App.shortcutIndex] != .recentlyFocused,
           let lastFocusedOrderWindowIndex = getLastFocusedOrderWindowIndex() {
            updateSelectedAndHoveredWindowIndex(lastFocusedOrderWindowIndex)
        } else {
            // edge-case: when the 2 most recently focused windows are both minimized, select the first
            if list.count >= 2 && list[0].isMinimized && list[1].isMinimized {
                updateSelectedAndHoveredWindowIndex(0)
            } else {
                cycleSelectedWindowIndex(1)
                if selectedWindowIndex == 0 {
                    updateSelectedAndHoveredWindowIndex(0)
                }
            }
        }
    }

    static func updateSelectedWindow() {
        let focusedWindowTarget = currentFocusedWindowTarget()
        defer { lastFocusedWindowTarget = focusedWindowTarget }
        if shouldRestoreDefaultSelectionOnSearchClear {
            shouldRestoreDefaultSelectionOnSearchClear = false
            setInitialSelectedAndHoveredWindowIndex()
            return
        }
        let visibleIndexes = visibleWindowIndexes()
        guard let firstVisibleIndex = visibleIndexes.first else {
            selectedWindowTarget = nil
            hoveredWindowIndex = nil
            return
        }
        if shouldSelectBestMatchOnSearchChange {
            shouldSelectBestMatchOnSearchChange = false
            updateSelectedAndHoveredWindowIndex(firstVisibleIndex)
            return
        }
        if shouldSelectFromScratch(focusedWindowTarget) {
            setInitialSelectedAndHoveredWindowIndex()
            return
        }
        if restoreSelectionTargetIfVisible() { return }
        adaptSelectionToVisibleIndexes(visibleIndexes, firstVisibleIndex)
    }

    private static func visibleWindowIndexes() -> [Int] {
        list.indices.filter { shouldDisplay(list[$0]) }
    }

    private static func currentFocusedWindowTarget() -> String? {
        getLastFocusedOrderWindowIndex().map { list[$0].id }
    }

    private static func shouldSelectFromScratch(_ focusedWindowTarget: String?) -> Bool {
        selectedWindowTarget == nil || focusedWindowChangedWhileShowing(focusedWindowTarget)
    }

    private static func focusedWindowChangedWhileShowing(_ focusedWindowTarget: String?) -> Bool {
        guard App.appIsBeingUsed, Search.normalizedQuery(searchQuery).isEmpty else { return false }
        guard let lastFocusedWindowTarget, let focusedWindowTarget else { return false }
        return focusedWindowTarget != lastFocusedWindowTarget
    }

    private static func restoreSelectionTargetIfVisible() -> Bool {
        guard let selectedWindowTarget else { return false }
        guard let index = list.firstIndex(where: { $0.id == selectedWindowTarget && shouldDisplay($0) }) else { return false }
        if index == selectedWindowIndex { return true }
        updateSelectedAndHoveredWindowIndex(index)
        return true
    }

    private static func adaptSelectionToVisibleIndexes(_ visibleIndexes: [Int], _ firstVisibleIndex: Int) {
        guard let lastVisibleIndex = visibleIndexes.last else { return }
        if !visibleIndexes.contains(selectedWindowIndex) {
            let closest = visibleIndexes.last(where: { $0 < selectedWindowIndex }) ?? lastVisibleIndex
            updateSelectedAndHoveredWindowIndex(closest)
            return
        }
        if selectedWindowIndex > lastVisibleIndex {
            updateSelectedAndHoveredWindowIndex(lastVisibleIndex)
            return
        }
        if selectedWindowIndex < firstVisibleIndex {
            updateSelectedAndHoveredWindowIndex(firstVisibleIndex)
            return
        }
        if selectedWindowTarget == nil {
            selectedWindowTarget = list[selectedWindowIndex].id
        }
    }

    static func updateSelectedAndHoveredWindowIndex(_ newIndex: Int, _ fromMouse: Bool = false) {
        guard newIndex >= 0 && newIndex < list.count else { return }
        guard shouldDisplay(list[newIndex]) else { return }
        var index: Int?
        if fromMouse && (newIndex != hoveredWindowIndex || lastWindowActivityType == .focus) {
            let oldIndex = hoveredWindowIndex
            hoveredWindowIndex = newIndex
            if let oldIndex {
                TilesView.highlight(oldIndex)
            }
            index = hoveredWindowIndex
            lastWindowActivityType = .hover
        }
        if !fromMouse {
            TilesView.thumbnailOverView.resetHoveredWindow()
        }
        if (!fromMouse || Preferences.mouseHoverEnabled)
               && (newIndex != selectedWindowIndex || lastWindowActivityType == .hover) {
            let oldIndex = selectedWindowIndex
            selectedWindowIndex = newIndex
            selectedWindowTarget = list[newIndex].id
            TilesView.highlight(oldIndex)
            previewSelectedWindowIfNeeded()
            index = selectedWindowIndex
            lastWindowActivityType = .focus
        }
        guard let index else { return }
        TilesView.highlight(index)
        let focusedView = TilesView.recycledViews[index]
        TilesView.scrollView.contentView.scrollToVisible(focusedView.frame)
        voiceOverWindow(index)
    }

    static func cycleSelectedWindowIndex(_ step: Int, allowWrap: Bool = true) {
        guard App.appIsBeingUsed else { return }
        guard list.contains(where: { shouldDisplay($0) }) else { return }
        let nextIndex = selectedWindowIndexAfterCycling(step)
        // don't wrap-around at the end, if key-repeat
        if (((step > 0 && nextIndex < selectedWindowIndex) || (step < 0 && nextIndex > selectedWindowIndex)) &&
            (!allowWrap || ATShortcut.lastEventIsARepeat || !KeyRepeatTimer.timerIsSuspended))
               // don't cycle to another row, if !allowWrap
               || (!allowWrap && list[nextIndex].rowIndex != list[selectedWindowIndex].rowIndex) {
            return
        }
        updateSelectedAndHoveredWindowIndex(nextIndex)
        // Pre-capture the newly selected window for the overlay
        if let window = selectedWindow(),
           let wid = window.cgWindowId,
           let pos = window.position, let sz = window.size {
            if #available(macOS 14.0, *) {
                FocusOverlay.preCapture(wid: wid, position: pos, size: sz)
            }
        }
    }

    static func selectedWindowIndexAfterCycling(_ step: Int) -> Int {
        if list.count == 0 || !list.contains(where: { shouldDisplay($0) }) { return selectedWindowIndex }
        var iterations = 0
        var targetIndex = selectedWindowIndex
        repeat {
            let next = (targetIndex + step) % list.count
            targetIndex = next < 0 ? list.count + next : next
            iterations += 1
        } while !shouldDisplay(list[targetIndex]) && iterations <= list.count
        return targetIndex
    }

    /// lastFocusOrder methods
    //////////////////////////////

    /// Updates windows "lastFocusOrder" to ensure unique values based on window z-order.
    /// Windows are ordered by their position in Spaces.windowsInSpaces() results,
    /// with topmost windows first.
    static func sortByLevel() {
        var windowLevelMap = [CGWindowID?: Int]()
        for (index, cgWindowId) in Spaces.windowsInSpaces(Spaces.visibleSpaces).enumerated() {
            windowLevelMap[cgWindowId] = index
        }
        list = list
        .sorted { w1, w2 in
            (windowLevelMap[w1.cgWindowId] ?? .max) < (windowLevelMap[w2.cgWindowId] ?? .max)
        }
        .enumerated()
        .map { (index, window) -> Window in
            window.lastFocusOrder = index
            return window
        }
    }

    /// reordered list based on preferences, keeping the original index
    private static func sort() {
        let trimmedQuery = Search.normalizedQuery(searchQuery)
        list.sort {
            if !trimmedQuery.isEmpty {
                let matches0 = Search.matches($0, query: trimmedQuery)
                let matches1 = Search.matches($1, query: trimmedQuery)
                if matches0 != matches1 { return matches0 }
                let score0 = Search.relevance(for: $0, query: trimmedQuery)
                let score1 = Search.relevance(for: $1, query: trimmedQuery)
                if score0 != score1 { return score0 > score1 }
                return $0.lastFocusOrder < $1.lastFocusOrder
            }
            // separate buckets for these types of windows
            if Preferences.showWindowlessApps[App.shortcutIndex] == .showAtTheEnd && $0.isWindowlessApp != $1.isWindowlessApp {
                return $1.isWindowlessApp
            }
            if Preferences.showHiddenWindows[App.shortcutIndex] == .showAtTheEnd && $0.isHidden != $1.isHidden {
                return $1.isHidden
            }
            if Preferences.showMinimizedWindows[App.shortcutIndex] == .showAtTheEnd && $0.isMinimized != $1.isMinimized {
                return $1.isMinimized
            }
            // sort within each buckets
            let sortType = Preferences.windowOrder[App.shortcutIndex]
            if sortType == .recentlyFocused {
                return $0.lastFocusOrder < $1.lastFocusOrder
            }
            if sortType == .recentlyCreated {
                return $1.creationOrder < $0.creationOrder
            }
            var order = ComparisonResult.orderedSame
            if sortType == .alphabetical {
                order = compareByAppNameThenWindowTitle($0, $1)
            }
            if sortType == .space {
                if $0.isOnAllSpaces && $1.isOnAllSpaces {
                    order = .orderedSame
                } else if $0.isOnAllSpaces {
                    order = .orderedAscending
                } else if $1.isOnAllSpaces {
                    order = .orderedDescending
                } else if let spaceIndex0 = $0.spaceIndexes.first, let spaceIndex1 = $1.spaceIndexes.first {
                    order = spaceIndex0.compare(spaceIndex1)
                }
                if order == .orderedSame {
                    order = compareByAppNameThenWindowTitle($0, $1)
                }
            }
            if order == .orderedSame {
                order = $0.lastFocusOrder.compare($1.lastFocusOrder)
            }
            return order == .orderedAscending
        }
    }

    static func getLastFocusedOrderWindowIndex() -> Int? {
        var index: Int? = nil
        var lastFocusOrderMin = Int.max
        for (offset, w) in list.enumerated() {
            if !w.isWindowlessApp && shouldDisplay(w) && w.lastFocusOrder < lastFocusOrderMin {
                lastFocusOrderMin = w.lastFocusOrder
                index = offset
            }
        }
        return index
    }

    static func updateLastFocusOrder(_ focusedWindow: Window) -> [Window]? {
        // no need to update the list is the window is already lastFocusOrder 0
        guard focusedWindow.lastFocusOrder != 0 && list.count > 1, let previousFocus = (list.first { $0.lastFocusOrder == 0 }) else {
            prewarmLikelyFocusTargets()
            return [focusedWindow]
        }
        // 2 windows have recently changed: the one which got focused, and the one who just lost focus
        let windowsToRefresh = [focusedWindow, previousFocus]
        let focusedWindowOldFocusOrder = focusedWindow.lastFocusOrder
        list.forEach {
            if $0.lastFocusOrder == focusedWindowOldFocusOrder {
                $0.lastFocusOrder = 0
            } else if $0.lastFocusOrder < focusedWindowOldFocusOrder {
                $0.lastFocusOrder += 1
            }
        }
        prewarmLikelyFocusTargets()
        return windowsToRefresh
    }

    static func prewarmLikelyFocusTargets(limit: Int = 1) {
        list
            .filter { shouldDisplay($0) }
            .sorted { $0.lastFocusOrder < $1.lastFocusOrder }
            .dropFirst()
            .prefix(limit)
            .forEach { $0.prewarmNativeFocusAxElementIfNeeded() }
    }

    static func findOrCreate(_ windowAxUiElement: AXUIElement, _ wid: CGWindowID, _ app: Application, _ level: CGWindowLevel, _ title: String?, _ subrole: String?, _ role: String?, _ size: CGSize?, _ position: CGPoint?, _ isFullscreen: Bool?, _ isMinimized: Bool?) -> (Window?, Bool) {
        if let window = (list.first { $0.isEqualRobust(windowAxUiElement, wid) }) {
            // on any window event, we take the opportunity to refresh all window attributes
            window.updateFromAxAttributes(title, size, position, isFullscreen, isMinimized)
            return (window, false)
        }
        guard WindowDiscriminator.isActualWindow(app, wid, level, title, subrole, role, size) else { return (nil, false) }
        let window = Window(windowAxUiElement, app, wid, title, isFullscreen, isMinimized, position, size)
        appendWindow(window)
        return (window, true)
    }

    static func appendWindow(_ window: Window) {
        window.lastFocusOrder = list.count
        list.append(window)
        if list.count > TilesView.recycledViews.count {
            TilesView.recycledViews.append(TileView())
        }
    }

    static func removeWindows(_ windows: [Window], _ addWindowlessWindowIfNeeded: Bool) {
        for w in windows {
            if w.application.focusedWindow?.cgWindowId == w.cgWindowId {
                w.application.focusedWindow = nil
            }
        }
        let toRemove = windows.map { $0.lastFocusOrder }
        list.removeAll { w in
            if toRemove.contains(w.lastFocusOrder) {
                return true
            }
            let howManyToShift = toRemove.reduce(0) { $1 < w.lastFocusOrder ? $0 + 1 : $0 }
            w.lastFocusOrder -= howManyToShift
            return false
        }
        for w in windows {
            if let wid = w.cgWindowId {
                AXCallScheduler.shared.removeEntry(key: "wid-\(wid)")
                Applications.windowListUpdateThrottler.removeEntry(withKey: "\(wid)")
            }
            // when a tabbed window is removed, update its former siblings' tab group
            if let siblingWids = w.tabbedSiblingWids {
                TabGroup.removedWindowFromGroup(wid: w.cgWindowId, siblingWids: siblingWids)
            }
        }
        if addWindowlessWindowIfNeeded {
            windows.forEach { $0.application.addWindowlessWindowIfNeeded() }
        }
        // Clear orphaned TileViews. `recycledViews` is append-only — it
        // grows to peak window count and never shrinks. Now that `list`
        // is shorter, indices `[list.count, recycledViews.count)` keep a
        // strong `window_` reference to the Window we just removed, plus
        // an IOSurface in the thumbnail layer's `contents`. Both pin the
        // Window alive (preventing its `thumbnail: CALayerContents?`
        // from releasing too) and pile up across hours of churn —
        // observed as ~370 MB unique footprint + 700+ IOSurface regions
        // after a 30-hour session. Releasing the orphans here is what
        // actually frees the chain. (Window.deinit then runs and tears
        // down the AX observer; see deinit comment.)
        for i in list.count..<TilesView.recycledViews.count {
            let view = TilesView.recycledViews[i]
            view.window_ = nil
            view.thumbnail.releaseImage()
        }
        lastFocusedWindowTarget = getLastFocusedOrderWindowIndex().map { list[$0].id }
        App.refreshOpenUiAfterExternalEvent([], windowRemoved: true)
    }
}

enum WindowActivityType: Int {
    case none = 0
    case hover = 1
    case focus = 2
}
