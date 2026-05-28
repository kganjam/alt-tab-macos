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
            hotJitterSec: Double(RuntimeFlags.bgThumbnailHotJitterMs) / 1000,
            warmJitterSec: Double(RuntimeFlags.bgThumbnailWarmJitterMs) / 1000
        ))
    }

    /// Register a newly-discovered window with a jittered initial delay so
    /// the first-time burst across N new windows is spread across the
    /// initial interval rather than all firing at once.
    func register(window: Window) {
        guard RuntimeFlags.bgThumbnailRefreshEnabled else { return }
        guard let wid = window.cgWindowId else { return }
        let initialDelay = Double.random(in: 0...Double(RuntimeFlags.bgThumbnailInitialMaxDelayMs) / 1000)
        let tier = tier(for: wid)
        ThumbnailCache.shared.register(wid: wid, tier: tier, initialDelay: initialDelay)
    }

    func unregister(window: Window) {
        guard let wid = window.cgWindowId else { return }
        ThumbnailCache.shared.unregister(wid: wid)
    }

    // MARK: - Tick

    private func tick() {
        let now = CFAbsoluteTimeGetCurrent()

        // Panel-open: the in-panel `visibleThumbnailRefreshTimer` (1200ms
        // default) takes over. Skip to avoid double-refreshing.
        if App.appIsBeingUsed { return }

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
                if let window = widToWindow[item.wid] {
                    Windows.refreshThumbnailsAsync([window], .backgroundPeriodic)
                } else {
                    // Window disappeared between popDue and main-thread
                    // dispatch. Reset in-flight so we don't leak it.
                    ThumbnailCache.shared.clearInFlight(wid: item.wid)
                }
            }
        }
    }

    // MARK: - Tiering

    /// Recompute hot vs warm tier assignments based on the current focus
    /// order. Top N windows by `lastFocusOrder` are hot.
    private func recomputeTiers() {
        DispatchQueue.main.async {
            let hotWids = self.currentHotWids()
            for w in Windows.list {
                guard let wid = w.cgWindowId else { continue }
                ThumbnailCache.shared.setTier(
                    wid: wid,
                    tier: hotWids.contains(wid) ? .hot : .warm
                )
            }
        }
    }

    /// Compute hot-tier wids from `Windows.list`. MUST be called on main.
    private func currentHotWids() -> Set<CGWindowID> {
        let hotSize = max(0, RuntimeFlags.bgThumbnailHotTierSize)
        guard hotSize > 0 else { return [] }
        let sorted = Windows.list.sorted { $0.lastFocusOrder > $1.lastFocusOrder }
        return Set(sorted.prefix(hotSize).compactMap { $0.cgWindowId })
    }

    /// Tier for a single wid. Best-effort lookup of current hot set; this
    /// is called from `register(window:)` which may run off-main, but
    /// `Windows.list` reads are safe-ish (we tolerate a stale snapshot
    /// here since `recomputeTiers` will correct it within seconds).
    private func tier(for wid: CGWindowID) -> ThumbnailCache.Tier {
        let hotWids = currentHotWids()
        return hotWids.contains(wid) ? .hot : .warm
    }
}
