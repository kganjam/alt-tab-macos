import Cocoa

/// Background loop that periodically refreshes window thumbnails when
/// AltTab's panel is closed. Pops due windows from `ThumbnailCache` and
/// dispatches captures via `Windows.refreshThumbnailsAsync`.
///
/// Pauses for `bgThumbnailPostSelectionPauseSec` after every alt-tab
/// commit (`App.lastAltTabFocusAt`) so capture traffic doesn't compete
/// with the focus handoff.
///
/// Tiering: top-N most recently focused windows (`Windows.list` sorted by
/// `lastFocusOrder` descending) refresh at `bgThumbnailHotIntervalSec`
/// (default 5s ± 1s jitter). Others at `bgThumbnailWarmIntervalSec`
/// (default 10s ± 2s jitter).
final class BackgroundThumbnailRefresher {
    static let shared = BackgroundThumbnailRefresher()

    /// Serial queue at `.utility` QoS — runs the tick handler and owns
    /// the timer. `.utility` is "long-running work the user knows about";
    /// it is reduced priority but NOT throttled by AppNap / battery /
    /// thermal pressure the way `.background` is. For a reliable 5-second
    /// cadence, `.background` would be too aggressive.
    private let queue = DispatchQueue(label: "altTab.bgThumbnailRefresher", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var tierRecomputeCounter = 0
    private var reconcileCounter = 0
    private var residencyTouchCounter = 0
    /// Hot-tier wids from the last `recomputeTiers`, reused by `register` so
    /// new-window registration doesn't re-sort the whole window list each time
    /// (O(n log n) per window → O(n² log n) during a discovery burst). Touched
    /// only on the main thread (recomputeTiers' main hop + register via
    /// appendWindow). Empty until the first recompute, which just means newly
    /// discovered windows start at warm/cold and are promoted within one
    /// recompute cycle (~4s) — harmless.
    private var cachedHotWids = Set<CGWindowID>()

    /// Start the timer. Idempotent. Must be called once the app has
    /// permissions and `Windows.list` is being populated.
    func start() {
        applyScheduleFromPreferences()
        queue.async { [weak self] in
            guard let self else { return }
            guard self.timer == nil else { return }
            guard RuntimeFlags.bgThumbnailRefreshEnabled else {
                Logger.info { "BackgroundThumbnailRefresher disabled by preferences" }
                return
            }
            let intervalMs = max(100, RuntimeFlags.bgThumbnailTickIntervalMs)
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + .milliseconds(intervalMs),
                       repeating: .milliseconds(intervalMs),
                       leeway: .milliseconds(intervalMs / 4))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
            Logger.info { "BackgroundThumbnailRefresher started tick=\(intervalMs)ms" }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    /// Push current Preferences into the cache so post-capture reschedules
    /// use the latest intervals/jitter. Call after preference changes too.
    func applyScheduleFromPreferences() {
        ThumbnailCache.shared.configure(ThumbnailCache.Schedule(
            hotIntervalSec: Double(RuntimeFlags.bgThumbnailHotIntervalMs) / 1000,
            warmIntervalSec: Double(RuntimeFlags.bgThumbnailWarmIntervalMs) / 1000,
            coldIntervalSec: Double(RuntimeFlags.bgThumbnailColdIntervalMs) / 1000,
            hotJitterSec: Double(RuntimeFlags.bgThumbnailHotJitterMs) / 1000,
            warmJitterSec: Double(RuntimeFlags.bgThumbnailWarmJitterMs) / 1000,
            coldJitterSec: Double(RuntimeFlags.bgThumbnailColdJitterMs) / 1000,
            firstThumbnailRetrySec: Double(RuntimeFlags.bgThumbnailFirstRetryMs) / 1000
        ))
    }

    /// Register a newly-discovered window with a jittered initial delay so
    /// the first-time burst across N new windows is spread across the
    /// initial interval rather than all firing at once.
    func register(window: Window) {
        guard RuntimeFlags.bgThumbnailRefreshEnabled else { return }
        guard let wid = window.cgWindowId else { return }
        let initialDelay = Double.random(in: 0...Double(RuntimeFlags.bgThumbnailInitialMaxDelayMs) / 1000)
        let tier = tierFor(window, hotWids: cachedHotWids)
        ThumbnailCache.shared.register(wid: wid, tier: tier, initialDelay: initialDelay)
    }

    func unregister(window: Window) {
        guard let wid = window.cgWindowId else { return }
        ThumbnailCache.shared.unregister(wid: wid)
    }

    /// Event-driven refresh for windows that just became active: a focus /
    /// foreground change (alt-tab, click-to-focus, app activation). Pull each
    /// window's next capture forward to now and promote it to the hot tier, so
    /// the switcher shows a fresh image of what the user just used/left without
    /// waiting out the periodic cadence. The actual capture still runs through
    /// the tick's maxPerTick/maxConcurrent gate, so this can't burst the server.
    /// Called with the focused window and the one it just displaced.
    func noteRecentlyActive(_ windows: [Window]) {
        guard RuntimeFlags.bgThumbnailRefreshEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        for window in windows {
            guard let wid = window.cgWindowId else { continue }
            ThumbnailCache.shared.setTier(wid: wid, tier: .hot)
            ThumbnailCache.shared.bumpUp(wid: wid, to: now)
        }
    }

    // MARK: - Tick

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()

        // Reconcile against the live window list on a steady cadence so
        // thumbnails (and their IOSurfaces) for windows that closed without
        // an AX-destroyed event are released even if the user never opens
        // the switcher. Runs regardless of the capture gating below.
        maybeReconcile()

        // Panel-open: the in-panel `visibleThumbnailRefreshTimer` (1200ms
        // default) takes over. Skip to avoid double-refreshing.
        if App.appIsBeingUsed { return }

        // Keep the small downscaled thumbnails resident while idle so a cold
        // panel show composites them directly instead of faulting ~130
        // memory-compressed bitmaps in the first frame (the ~500ms cold cost).
        // Every ~15s, dispatched off this serial queue so the read (~130ms)
        // doesn't delay the capture cadence.
        residencyTouchCounter += 1
        if residencyTouchCounter >= 30 {
            residencyTouchCounter = 0
            DispatchQueue.global(qos: .utility).async { ThumbnailCache.shared.touchForResidency() }
        }

        // Post-selection pause: catches the case where the user has
        // committed an alt-tab choice but the OS is still settling the
        // focus handoff. Configurable via `bgThumbnailPostSelectionPauseSec`
        // (default 3.0).
        let pauseSec = Double(RuntimeFlags.bgThumbnailPostSelectionPauseMs) / 1000
        if App.lastAltTabFocusAt > 0 && now - App.lastAltTabFocusAt < pauseSec {
            return
        }

        // Back-pressure: don't pile on if many captures are already in
        // flight (from in-panel timer, AX events, etc.).
        if ActiveWindowCaptures.value() >= RuntimeFlags.bgThumbnailMaxConcurrent { return }

        tierRecomputeCounter += 1
        if tierRecomputeCounter >= 8 {
            tierRecomputeCounter = 0
            recomputeTiers()
        }

        let due = ThumbnailCache.shared.popDue(now: now, max: RuntimeFlags.bgThumbnailMaxPerTick)
        guard !due.isEmpty else { return }
        Logger.debug { "bgRefresh due=\(due.count)" }

        // Hop to main to safely read `Windows.list`. Each capture goes
        // through `Windows.refreshThumbnailsAsync` individually so failures
        // (window vanished, gate active, etc.) are scoped per-window.
        DispatchQueue.main.async {
            let widToWindow: [CGWindowID: Window] = Dictionary(
                uniqueKeysWithValues: Windows.list.compactMap { w in
                    guard let wid = w.cgWindowId else { return nil as (CGWindowID, Window)? }
                    return (wid, w)
                }
            )
            for item in due {
                guard let window = widToWindow[item.wid] else {
                    // Window disappeared between popDue and main-thread
                    // dispatch. Reset in-flight so we don't leak it.
                    ThumbnailCache.shared.clearInFlight(wid: item.wid)
                    continue
                }
                // Minimized windows have frozen content and can't be captured
                // by SCK (which would force the costly CGSHWCaptureWindowList
                // fallback that feeds WindowServer's surface tally). Skip them
                // in the background entirely; the in-panel refresh populates
                // their thumbnail when the switcher is actually shown.
                if window.isMinimized {
                    ThumbnailCache.shared.clearInFlight(wid: item.wid)
                    continue
                }
                Windows.refreshThumbnailsAsync([window], .backgroundPeriodic)
            }
        }
    }

    // MARK: - Tiering

    /// Recompute hot vs warm tier assignments based on the current focus
    /// order. Top N windows by `lastFocusOrder` are hot.
    private func recomputeTiers() {
        DispatchQueue.main.async {
            let hotWids = self.currentHotWids()
            self.cachedHotWids = hotWids
            let now = CFAbsoluteTimeGetCurrent()
            let hotInterval = Double(RuntimeFlags.bgThumbnailHotIntervalMs) / 1000
            for w in Windows.list {
                guard let wid = w.cgWindowId else { continue }
                let tier = self.tierFor(w, hotWids: hotWids)
                ThumbnailCache.shared.setTier(wid: wid, tier: tier)
                // On promotion to hot, pull the next refresh forward so the
                // window enters the fast cadence promptly rather than waiting
                // out a stale warm/cold deadline (up to 5 min). bumpUp is a
                // no-op when the existing deadline is already sooner, so this
                // costs nothing for already-hot windows.
                if tier == .hot {
                    ThumbnailCache.shared.bumpUp(wid: wid, to: now + hotInterval)
                }
            }
        }
    }

    /// Reconcile our window list with the live system window list, releasing
    /// thumbnails for windows that vanished without an AX-destroyed event.
    /// Cheap (one WindowServer query off-main) and runs on its own cadence
    /// independent of capture gating.
    private func maybeReconcile() {
        let tickMs = max(1, RuntimeFlags.bgThumbnailTickIntervalMs)
        let everyTicks = max(1, RuntimeFlags.bgThumbnailReconcileMs / tickMs)
        reconcileCounter += 1
        guard reconcileCounter >= everyTicks else { return }
        reconcileCounter = 0
        // Emit the thumbnail-cache/IOSurface profiler line and reconcile on main: `windows` is the
        // tracked/live window count (Windows.list, main-thread-only) and `surfaces` is the count of
        // held IOSurface-backed thumbnails. Both must stay bounded (≈ live windows) and NOT grow over
        // a long session — that's the regression signal for the WindowServer surface-tally crash.
        DispatchQueue.main.async {
            if Diagnostics.shouldLog("THUMBCACHE") {
                let captures = CaptureBackendCounters.snapshot()
                Diagnostics.log("THUMBCACHE", "windows=\(Windows.list.count) \(ThumbnailCache.shared.statsLine()) activeCaptures=\(ActiveWindowCaptures.value()) cgsCaptures=\(captures.cgs) sckCaptures=\(captures.sck) selfRss=\(selfResidentMB())MB panelOpen=\(App.appIsBeingUsed)")
            }
            Applications.removeZombieWindows()
            // Self-heal the AX↔WindowServer bridge if a WindowServer crash left it
            // dead (every app's kAXWindows empty while windows demonstrably exist).
            Applications.recoverFromDeadAxBridgeIfNeeded()
        }
    }

    /// Compute hot-tier wids from `Windows.list`. MUST be called on main.
    private func currentHotWids() -> Set<CGWindowID> {
        let hotSize = max(0, RuntimeFlags.bgThumbnailHotTierSize)
        guard hotSize > 0 else { return [] }
        let sorted = Windows.list
            .filter { !$0.isMinimized && !$0.isWindowlessApp }
            .sorted { $0.lastFocusOrder > $1.lastFocusOrder }
        return Set(sorted.prefix(hotSize).compactMap { $0.cgWindowId })
    }

    /// Classify a window into a refresh tier. Reads `Window` state and
    /// `Windows.list`, so it should be called on main (its callers —
    /// `register` via `appendWindow`, and `recomputeTiers` — both are).
    /// `hot` = recency top-N (live surfaces, fast cadence). `cold` =
    /// minimized, or not shown in the switcher (very slow cadence; minimized
    /// windows are additionally skipped at capture time). `warm` = the rest.
    private func tierFor(_ window: Window, hotWids: Set<CGWindowID>) -> ThumbnailCache.Tier {
        guard let wid = window.cgWindowId else { return .cold }
        if window.isMinimized { return .cold }
        if hotWids.contains(wid) { return .hot }
        return window.shouldShowTheUser ? .warm : .cold
    }
}

/// Resident memory of THIS process (AltTab), in MB, via proc_pidinfo — logged in
/// the THUMBCACHE line so AltTab's own footprint is always tracked next to the
/// capture metrics (it's a real signal: ~905MB on SCK vs ~303MB on CGS).
/// WindowServer's footprint — the metric behind the 30GB watchdog hang — can NOT
/// be read in-process: it runs as uid 88 and proc_pidinfo is blocked cross-user
/// (verified). The com.kganjam.ws-mem-watch LaunchAgent samples WindowServer via
/// `ps` instead.
private func selfResidentMB() -> Int {
    var ti = proc_taskinfo()
    let sz = Int32(MemoryLayout<proc_taskinfo>.size)
    guard proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &ti, sz) == sz else { return -1 }
    return Int(ti.pti_resident_size / 1024 / 1024)
}
