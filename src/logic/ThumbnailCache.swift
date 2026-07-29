import Cocoa

/// Thread-safe per-window thumbnail storage + min-heap priority queue for
/// the background refresh scheduler.
///
/// Owns:
/// - The bitmap (`CALayerContents`) for each window. Written from any
///   thread; read from any thread; protected by `lock`. `Window.thumbnail`
///   is a pass-through computed property that reads from here.
/// - A min-heap keyed by per-window next-refresh deadline. The
///   `BackgroundThumbnailRefresher` pops due windows on each tick.
///
/// Tombstone detection: each scheduled deadline is tagged with a global
/// monotonic `scheduleId`. A popped heap entry is valid iff
/// `entries[wid].scheduleId == heapEntry.scheduleId` (per-window equality).
/// Reschedules of one window bump only that window's scheduleId, so other
/// windows' heap entries are never invalidated — the equality check is
/// per-wid, not cross-wid.
final class ThumbnailCache {
    static let shared = ThumbnailCache()

    /// Refresh-cadence tiers. `hot` = top-N most-recently-focused (kept with
    /// live IOSurfaces, fast cadence). `warm` = other windows the user would
    /// see in the switcher (detached bitmaps, slow cadence). `cold` =
    /// off-screen / hidden / minimized (detached bitmaps, very slow cadence;
    /// minimized windows are skipped entirely by the refresher).
    enum Tier { case hot, warm, cold }

    struct PoppedItem {
        let wid: CGWindowID
        let scheduleId: UInt64
        let tier: Tier
    }

    /// Limits passed by `BackgroundThumbnailRefresher` on startup. We
    /// keep them here so `writeCapture` can reschedule without re-reading
    /// `Preferences` from arbitrary threads.
    struct Schedule {
        var hotIntervalSec: TimeInterval = 5
        var warmIntervalSec: TimeInterval = 60
        var coldIntervalSec: TimeInterval = 300
        var hotJitterSec: TimeInterval = 1
        var warmJitterSec: TimeInterval = 5
        var coldJitterSec: TimeInterval = 30
        /// If a captured window's `scheduleId` matches what we handed out
        /// in `popDue` for an in-flight capture, we push a new heap entry
        /// using the tier's interval ± jitter. If a capture takes longer
        /// than this, the watchdog resets it.
        var inFlightTimeoutSec: TimeInterval = 15
        /// Retry cadence for a shown (hot/warm) window that still has NO
        /// thumbnail after a failed/skipped capture — kept short so every
        /// visible window gets a first image quickly, independent of the long
        /// steady-state tier intervals. Cold (minimized/hidden) windows are
        /// excluded: they can't be captured until shown, so they keep the slow
        /// cold cadence rather than spinning here.
        var firstThumbnailRetrySec: TimeInterval = 3
        /// Idle backoff ceiling. When a window's captured content is byte-identical
        /// to its previous capture it's static, so its next-refresh interval is
        /// doubled per consecutive unchanged capture, clamped to this. A change or
        /// an activation drops it back to the tier's base cadence. Set to 0 (or any
        /// value ≤ a tier's base interval) to disable backoff for that tier.
        var maxBackoffSec: TimeInterval = 600
        /// Consecutive capture timeouts (in-flight rescued without a completion
        /// callback) after which a window is quarantined: its background capture
        /// is suspended for `captureQuarantineSec` instead of being retried every
        /// tick. A window whose SCK/CGS capture never completes is almost always
        /// un-capturable (offscreen/Coherence/dead surface); re-dispatching it
        /// forever is what pinned `inFlight` at ~10 and hung WindowServer
        /// (watchdog-killed 2026-07-28). Below the threshold, each timeout backs
        /// the retry off exponentially (1s, 2s, 4s…) rather than a tight now+1s.
        var captureTimeoutQuarantineThreshold: Int = 3
        /// How long a quarantined window's background capture stays suspended.
        /// It still gets captured on demand when the panel opens or the window is
        /// activated (which resets the timeout streak), so a window that becomes
        /// capturable again recovers promptly.
        var captureQuarantineSec: TimeInterval = 300
    }

    private struct Entry {
        var thumbnail: CALayerContents?
        /// App-identity tag (pid:bundleId) of the window whose capture last wrote
        /// this wid's bitmap. Diagnostic only: lets us detect a thumbnail captured
        /// from one app being shown on a tile for a *different* app — the
        /// "Parallels tile shows another Parallels app's content" symptom, which
        /// implies a cgWindowId collision or Parallels reusing a wid across apps.
        var capturedBy: String?
        /// Perceptual aHash of the stored bitmap (0 if not computed). Diagnostic:
        /// two entries with the same non-zero signature but different wids means a
        /// shared/duplicate capture surface (Parallels Coherence cross-window).
        /// Coherence-scoped — drives cross-window dedup, so it stays 0 for normal
        /// windows (two genuinely-identical normal windows must NOT dedup-suppress).
        var signature: UInt64 = 0
        /// Exact content hash of THIS window's last captured bitmap, computed for
        /// every window (unlike `signature`). Compared across time (not across
        /// windows) to detect a static window and drive the idle refresh backoff.
        var contentHash: UInt64 = 0
        /// Consecutive background captures whose `contentHash` was unchanged. Grows
        /// the next-refresh interval (×2 each, capped at `schedule.maxBackoffSec`);
        /// reset to 0 by any content change, capture failure, or activation.
        var unchangedStreak: Int = 0
        /// True iff `thumbnail` is backed by a live WindowServer capture
        /// IOSurface (SCK pixelBuffer, or a non-detached CGSHWCaptureWindowList
        /// CGImage). False for malloc-backed detached copies. This is what
        /// counts against WindowServer's per-client IOSurface tally — detached
        /// copies do not. Distinguishing the two is the only way to verify the
        /// detach mitigation, since both live and detached results are stored
        /// as `.cgImage` when SCK is off.
        var isLiveSurface: Bool = false
        var lastUpdatedAt: CFAbsoluteTime = 0
        var nextRefreshAt: CFAbsoluteTime
        var scheduleId: UInt64
        var tier: Tier
        var inFlight: Bool = false
        var inFlightScheduleId: UInt64 = 0
        var inFlightSince: CFAbsoluteTime = 0
        /// Consecutive in-flight captures that timed out (rescued without a
        /// `writeCapture`/`rejectCapture`/`clearInFlight` completion). Drives the
        /// exponential retry backoff and quarantine in `rescueStuckInFlightLocked`;
        /// reset to 0 by any completion or activation so a recovered window
        /// resumes its normal cadence.
        var timeoutStreak: Int = 0
        /// True while this window is quarantined (capture suspended after
        /// `captureTimeoutQuarantineThreshold` consecutive timeouts). Diagnostic
        /// only — the suspension is enforced by the deferred heap deadline.
        var quarantined: Bool = false
    }

    private let lock = NSLock()
    private var entries: [CGWindowID: Entry] = [:]
    /// How many entries currently hold each non-zero content signature. A count
    /// > 1 means that bitmap is duplicated across windows (shared Coherence
    /// surface), so `read` suppresses it. Kept incrementally so reads stay O(1).
    private var signatureCounts: [UInt64: Int] = [:]
    private var heap = MinHeap<HeapEntry>()
    private var generation: UInt64 = 0
    private var schedule = Schedule()

    // MARK: - Configuration

    func configure(_ schedule: Schedule) {
        lock.lock(); defer { lock.unlock() }
        self.schedule = schedule
    }

    // MARK: - Registration

    func register(wid: CGWindowID, tier: Tier, initialDelay: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        if entries[wid] != nil {
            if entries[wid]!.tier != tier { entries[wid]!.tier = tier }
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let deadline = now + initialDelay
        generation &+= 1
        entries[wid] = Entry(thumbnail: nil,
                             nextRefreshAt: deadline,
                             scheduleId: generation,
                             tier: tier)
        heap.push(HeapEntry(deadline: deadline, wid: wid, scheduleId: generation))
    }

    func unregister(wid: CGWindowID) {
        lock.lock(); defer { lock.unlock() }
        if let s = entries[wid]?.signature { updateSignatureCountLocked(old: s, new: 0) }
        entries.removeValue(forKey: wid)
        // Heap entries for this wid become tombstones (entries[wid] == nil).
    }

    func setTier(wid: CGWindowID, tier: Tier) {
        lock.lock(); defer { lock.unlock() }
        guard entries[wid] != nil, entries[wid]!.tier != tier else { return }
        entries[wid]!.tier = tier
        // We don't immediately reschedule: the current deadline stays
        // valid. The tier change takes effect on the next capture's
        // post-completion reschedule.
    }

    // MARK: - Read

    /// Read the thumbnail bitmap. Lock-protected; fast on uncontended path.
    /// Content dedup: if this bitmap is pixel-identical to another window's
    /// (Parallels Coherence returned one shared guest surface for several window
    /// ids), return nil so the tile falls back to its app icon instead of showing
    /// another window's content. Real windows have unique pixels, so they're
    /// unaffected; non-Coherence captures carry no signature and never dedup.
    func read(wid: CGWindowID) -> CALayerContents? {
        lock.lock(); defer { lock.unlock() }
        guard let e = entries[wid] else { return nil }
        if e.signature != 0, (signatureCounts[e.signature] ?? 0) > 1 { return nil }
        return e.thumbnail
    }

    func lastUpdatedAt(wid: CGWindowID) -> CFAbsoluteTime {
        lock.lock(); defer { lock.unlock() }
        return entries[wid]?.lastUpdatedAt ?? 0
    }

    /// App-identity tag (pid:bundleId) of the window whose capture last wrote
    /// this wid's bitmap, or nil if never captured. Diagnostic for the
    /// cross-app-thumbnail symptom; see `Entry.capturedBy`.
    func capturedBy(wid: CGWindowID) -> String? {
        lock.lock(); defer { lock.unlock() }
        return entries[wid]?.capturedBy
    }

    /// Read every cached thumbnail's pixels so macOS keeps the (downscaled,
    /// <1MB) bitmaps resident — out of the memory compressor — while AltTab sits
    /// idle. A cold panel show then composites them directly instead of faulting
    /// ~130 compressed bitmaps in the first frame (the ~500ms cold-paint cost).
    /// MUST be called off the main thread; reads are serial with an autorelease
    /// pool so transient copies don't accumulate. No manual memory / mlock — just
    /// touches the pages so the LRU keeps them hot. Cheap (~1ms each).
    func touchForResidency() {
        lock.lock()
        let images: [CGImage] = entries.values.compactMap {
            if case let .cgImage(img)? = $0.thumbnail { return img }
            return nil
        }
        lock.unlock()
        guard !images.isEmpty else { return }
        let startedAt = CFAbsoluteTimeGetCurrent()
        for img in images {
            autoreleasepool { _ = img.dataProvider?.data }
        }
        Diagnostics.log("RESIDENCY", String(format: "touched %d thumbnails in %.0fms", images.count, (CFAbsoluteTimeGetCurrent() - startedAt) * 1000))
    }

    /// Current tier for a window, or nil if not registered. Used by the
    /// capture completion to decide whether to keep a live IOSurface (hot)
    /// or detach into a malloc-backed bitmap (warm/cold).
    func tier(wid: CGWindowID) -> Tier? {
        lock.lock(); defer { lock.unlock() }
        return entries[wid]?.tier
    }

    // MARK: - Write

    /// Store a captured thumbnail. If this corresponds to an in-flight BG
    /// capture (the popped scheduleId matches the current scheduleId), also
    /// reschedule the next BG refresh. If a `bumpUp`/manual reschedule
    /// happened during the capture, that party's heap entry stands and we
    /// don't push a new one.
    ///
    /// In-panel captures (`refreshVisibleThumbnailsAfterShowUi` source)
    /// don't set `inFlightScheduleId` (they didn't go through `popDue`), so
    /// they only store the bitmap and don't perturb BG scheduling.
    func writeCapture(wid: CGWindowID, image: CALayerContents, liveSurface: Bool = true, capturedBy: String? = nil, signature: UInt64 = 0, contentHash: UInt64 = 0) {
        lock.lock(); defer { lock.unlock() }
        guard entries[wid] != nil else { return }
        var e = entries[wid]!
        // Idle backoff: did this capture's content match the previous one? (A real
        // hash, computed for every window — distinct from the Coherence-only dedup
        // `signature`.) Must read e.contentHash before it's overwritten below.
        let contentUnchanged = contentHash != 0 && contentHash == e.contentHash && e.thumbnail != nil
        // Diagnostic: if this wid's capture writer changed app identity, the OS
        // reassigned the cgWindowId to a different app's window (Parallels
        // Coherence wid reuse) or two windows collide on one wid. Either way the
        // bitmap now under this key belongs to a different app than before.
        if let capturedBy, let prev = e.capturedBy, prev != capturedBy {
            Diagnostics.log("THUMBPROV", "wid=\(wid) capture writer changed: '\(prev)' -> '\(capturedBy)' — same cgWindowId now captured from a different app")
        }
        // Diagnostic: a non-zero signature matching a *different* wid's stored
        // bitmap means two windows captured pixel-identical content — Parallels
        // Coherence handing back one shared guest surface for multiple window ids,
        // so several tiles show the same wrong image. Provenance misses this
        // because each capture is correctly tagged by its requesting window.
        if signature != 0 {
            for (otherWid, oe) in entries where otherWid != wid && oe.signature == signature && oe.thumbnail != nil {
                Diagnostics.log("THUMBDUP", "wid=\(wid) (\(capturedBy ?? "?")) capture is pixel-identical to wid=\(otherWid) (\(oe.capturedBy ?? "?")) sig=\(signature) — shared/duplicate capture surface")
            }
        }
        if let capturedBy { e.capturedBy = capturedBy }
        updateSignatureCountLocked(old: e.signature, new: signature)
        e.signature = signature
        e.contentHash = contentHash
        e.thumbnail = image
        e.isLiveSurface = liveSurface
        e.lastUpdatedAt = CFAbsoluteTimeGetCurrent()
        finishCaptureLocked(&e, wid: wid, contentUnchanged: contentUnchanged)
    }

    /// A capture completed but came back unusable (e.g. an all-black Coherence
    /// frame for a guest window the VM isn't rendering). Drop the dud — clear the
    /// bitmap so the tile falls back to the app icon rather than showing black —
    /// and clear in-flight + reschedule at the tier's normal cadence, exactly as a
    /// successful capture would. Storing the black frame was the bug; this is the
    /// reject path. Reschedules (not fast first-thumbnail retry) so a persistently
    /// unrendered window isn't re-captured in a tight loop.
    func rejectCapture(wid: CGWindowID) {
        lock.lock(); defer { lock.unlock() }
        guard entries[wid] != nil else { return }
        var e = entries[wid]!
        e.thumbnail = nil
        e.isLiveSurface = false
        e.lastUpdatedAt = 0
        updateSignatureCountLocked(old: e.signature, new: 0)
        e.signature = 0
        e.contentHash = 0
        finishCaptureLocked(&e, wid: wid, contentUnchanged: false)
    }

    /// Adjust `signatureCounts` when an entry's signature changes. Caller holds
    /// `lock`. Zero is the "no signature" sentinel and is never counted.
    private func updateSignatureCountLocked(old: UInt64, new: UInt64) {
        guard old != new else { return }
        if old != 0 {
            if let c = signatureCounts[old], c > 1 { signatureCounts[old] = c - 1 }
            else { signatureCounts[old] = nil }
        }
        if new != 0 { signatureCounts[new, default: 0] += 1 }
    }

    /// Clear in-flight state and, if this was a BG-initiated capture, push the
    /// next deadline at the tier's normal cadence. Caller holds `lock` and has
    /// already set `e`'s content fields; we write `e` back and update the heap.
    private func finishCaptureLocked(_ e: inout Entry, wid: CGWindowID, contentUnchanged: Bool) {
        let wasBgInitiated = e.inFlight
        let poppedScheduleId = e.inFlightScheduleId
        e.inFlight = false
        e.inFlightScheduleId = 0
        e.inFlightSince = 0
        // The capture completed (success or a rejected dud), so WindowServer
        // serviced it — clear any timeout streak / quarantine.
        e.timeoutStreak = 0
        e.quarantined = false
        entries[wid] = e
        guard wasBgInitiated, e.scheduleId == poppedScheduleId else { return }
        // A static window (content byte-identical to its last capture) is polled
        // progressively less often; any change drops it back to the base cadence.
        e.unchangedStreak = contentUnchanged ? e.unchangedStreak + 1 : 0
        let now = CFAbsoluteTimeGetCurrent()
        let (interval, jitter) = intervalAndJitter(e.tier)
        let deadline = now + backedOffInterval(base: interval, streak: e.unchangedStreak) + Double.random(in: -jitter...jitter)
        generation &+= 1
        e.nextRefreshAt = deadline
        e.scheduleId = generation
        entries[wid] = e
        heap.push(HeapEntry(deadline: deadline, wid: wid, scheduleId: generation))
    }

    /// Exponentially grow a tier's base interval with the unchanged-capture
    /// streak, clamped to `schedule.maxBackoffSec`. Never shorter than `base`, so
    /// a tier whose base already meets/exceeds the ceiling is left untouched.
    private func backedOffInterval(base: TimeInterval, streak: Int) -> TimeInterval {
        guard streak > 0, schedule.maxBackoffSec > base else { return base }
        let grown = base * pow(2, Double(Swift.min(streak, 30)))
        return Swift.min(grown, schedule.maxBackoffSec)
    }

    /// Clear in-flight state without storing a bitmap (capture errored or
    /// the window was filtered out post-dispatch). Reschedules normally so
    /// we retry next interval.
    func clearInFlight(wid: CGWindowID) {
        lock.lock(); defer { lock.unlock() }
        guard entries[wid] != nil, entries[wid]!.inFlight else { return }
        var e = entries[wid]!
        let poppedScheduleId = e.inFlightScheduleId
        e.inFlight = false
        e.inFlightScheduleId = 0
        e.inFlightSince = 0
        e.unchangedStreak = 0
        // Reached the completion path (capture errored or the window was filtered
        // out post-dispatch), so this is not a WindowServer timeout — clear the
        // streak/quarantine.
        e.timeoutStreak = 0
        e.quarantined = false
        entries[wid] = e
        guard e.scheduleId == poppedScheduleId else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let (interval, _) = intervalAndJitter(e.tier)
        // A shown window with no thumbnail yet (failed/skipped first capture)
        // retries fast so it always ends up with at least one image; once it
        // has a thumbnail it falls back to the slow tier cadence. Cold windows
        // (minimized/hidden, not shown in the switcher) keep the long interval.
        let retry = (e.thumbnail == nil && e.tier != .cold)
            ? Swift.min(interval, schedule.firstThumbnailRetrySec)
            : interval
        generation &+= 1
        e.nextRefreshAt = now + retry
        e.scheduleId = generation
        entries[wid] = e
        heap.push(HeapEntry(deadline: e.nextRefreshAt, wid: wid, scheduleId: generation))
    }

    /// Move a window's next refresh earlier. No-op if the requested deadline is
    /// later than (or equal to) the current schedule, or if the window is
    /// quarantined: a quarantine exists precisely to stop re-hammering an
    /// un-capturable window, and pulling its deadline forward silently defeated
    /// it. Tier promotion bumps to `now + hotInterval` (60s), so a 300s
    /// quarantine was being re-armed every 60s — the 76s quarantine cycle that
    /// ran all night on 2026-07-29. Callers acting on real user activity clear
    /// the quarantine via `resetBackoff` first, so those bumps still land.
    func bumpUp(wid: CGWindowID, to requestedDeadline: CFAbsoluteTime) {
        lock.lock(); defer { lock.unlock() }
        guard entries[wid] != nil else { return }
        var e = entries[wid]!
        guard !e.quarantined else { return }
        guard requestedDeadline < e.nextRefreshAt else { return }
        generation &+= 1
        e.nextRefreshAt = requestedDeadline
        e.scheduleId = generation
        entries[wid] = e
        heap.push(HeapEntry(deadline: requestedDeadline, wid: wid, scheduleId: generation))
    }

    /// Clear the bitmap but keep the scheduling slot. Use on geometry
    /// change so the next capture repopulates at correct dimensions.
    func clearThumbnail(wid: CGWindowID) {
        lock.lock(); defer { lock.unlock() }
        guard entries[wid] != nil else { return }
        updateSignatureCountLocked(old: entries[wid]!.signature, new: 0)
        entries[wid]!.thumbnail = nil
        entries[wid]!.isLiveSurface = false
        entries[wid]!.lastUpdatedAt = 0
        entries[wid]!.signature = 0
        entries[wid]!.contentHash = 0
        entries[wid]!.unchangedStreak = 0
    }

    /// Drop a window back to its tier's base refresh cadence. Called when the
    /// window is activated (focus / foreground), so a window the user just
    /// returned to resumes fresh captures regardless of how long it had been
    /// statically backed off. The pulled-forward deadline is set separately by
    /// `bumpUp`; this only clears the accumulated backoff so it doesn't re-apply
    /// on the next reschedule.
    func resetBackoff(wid: CGWindowID) {
        lock.lock(); defer { lock.unlock() }
        guard entries[wid] != nil else { return }
        entries[wid]!.unchangedStreak = 0
        // The user returned to this window, so it's on-screen and capturable again:
        // lift any capture quarantine so its pulled-forward refresh actually fires.
        entries[wid]!.timeoutStreak = 0
        entries[wid]!.quarantined = false
    }

    // MARK: - Scheduling

    /// Return up to `max` windows whose deadlines have passed, sorted
    /// earliest-first. Marks each as in-flight. Also rescues windows
    /// whose previous capture leaked past `inFlightTimeoutSec` without a
    /// `writeCapture` or `clearInFlight` callback.
    func popDue(now: CFAbsoluteTime, max maxCount: Int) -> [PoppedItem] {
        lock.lock(); defer { lock.unlock() }
        rescueStuckInFlightLocked(now: now)
        drainTombstonesLocked()
        var result = [PoppedItem]()
        while let top = heap.peek(), top.deadline <= now, result.count < maxCount {
            heap.pop()
            guard entries[top.wid] != nil,
                  entries[top.wid]!.scheduleId == top.scheduleId,
                  !entries[top.wid]!.inFlight else { continue }
            entries[top.wid]!.inFlight = true
            entries[top.wid]!.inFlightScheduleId = top.scheduleId
            entries[top.wid]!.inFlightSince = now
            result.append(PoppedItem(wid: top.wid, scheduleId: top.scheduleId, tier: entries[top.wid]!.tier))
        }
        return result
    }

    /// Diagnostic snapshot.
    func snapshot() -> (entryCount: Int, heapSize: Int, nextDueIn: TimeInterval?) {
        lock.lock(); defer { lock.unlock() }
        let nextDue = heap.peek().map { $0.deadline - CFAbsoluteTimeGetCurrent() }
        return (entries.count, heap.count, nextDue)
    }

    /// One-line profiler/leak-tracking summary. `liveSurfaces` counts entries still holding an
    /// IOSurface-backed pixel buffer — the windows that count against WindowServer's per-client
    /// surface tally (the metric behind the WSIOSurfaceDebugTallyAndAbort crash). With the
    /// detach-non-hot-tier fix it should hover around `bgThumbnailHotTierSize` and NOT grow with the
    /// number of open windows; a rising `liveSurfaces` over a long session means the leak regressed.
    func statsLine() -> String {
        lock.lock(); defer { lock.unlock() }
        var hot = 0, warm = 0, cold = 0, inFlight = 0, pixelBuffer = 0, cgImage = 0
        var liveSurfaces = 0, detached = 0, backedOff = 0, quarantined = 0, timingOut = 0
        for (_, e) in entries {
            switch e.tier { case .hot: hot += 1; case .warm: warm += 1; case .cold: cold += 1 }
            if e.inFlight { inFlight += 1 }
            if e.unchangedStreak > 0 { backedOff += 1 }
            if e.quarantined { quarantined += 1 }
            else if e.timeoutStreak > 0 { timingOut += 1 }
            switch e.thumbnail {
            case .pixelBuffer?: pixelBuffer += 1
            case .cgImage?: cgImage += 1
            default: break
            }
            if e.thumbnail != nil {
                if e.isLiveSurface { liveSurfaces += 1 } else { detached += 1 }
            }
        }
        // `liveSurfaces` = thumbnails backed by a live WindowServer capture IOSurface — the metric that
        // counts against the per-client tally behind WSIOSurfaceDebugTallyAndAbort. With the detach
        // mitigation on it should stay ≈ hot-tier size and NOT grow with window count. `detached` are
        // malloc-backed copies that cost no WindowServer surface. `pixelBuffer`/`cgImage` are only the
        // raw storage split and do NOT distinguish live from detached (a detached copy is still .cgImage),
        // so `surfaces` (their sum) overcounts when detach is on — watch `liveSurfaces`, not `surfaces`.
        let surfaces = pixelBuffer + cgImage
        let nextDueMs = heap.peek().map { Int(($0.deadline - CFAbsoluteTimeGetCurrent()) * 1000) } ?? -1
        return "entries=\(entries.count) liveSurfaces=\(liveSurfaces) detached=\(detached) surfaces=\(surfaces) pixelBuffer=\(pixelBuffer) cgImage=\(cgImage) hot=\(hot) warm=\(warm) cold=\(cold) backedOff=\(backedOff) inFlight=\(inFlight) timingOut=\(timingOut) quarantined=\(quarantined) heap=\(heap.count) nextDueMs=\(nextDueMs)"
    }

    // MARK: - Internal

    /// Per-tier refresh interval and jitter. Callers already hold `lock`.
    private func intervalAndJitter(_ tier: Tier) -> (TimeInterval, TimeInterval) {
        switch tier {
        case .hot: return (schedule.hotIntervalSec, schedule.hotJitterSec)
        case .warm: return (schedule.warmIntervalSec, schedule.warmJitterSec)
        case .cold: return (schedule.coldIntervalSec, schedule.coldJitterSec)
        }
    }

    /// Reset entries whose in-flight capture leaked (dispatched but no
    /// `writeCapture`/`rejectCapture`/`clearInFlight` completion within
    /// `inFlightTimeoutSec`). A leaked capture means WindowServer never serviced
    /// the request — retrying it at now+1s every tick is exactly what pinned
    /// `inFlight` at ~10 and drove WindowServer into a watchdog-killed hang. So
    /// instead of an unconditional prompt retry: back the next attempt off
    /// exponentially with the per-window timeout streak, and once the streak
    /// crosses `captureTimeoutQuarantineThreshold`, quarantine the window —
    /// suspend its background capture for `captureQuarantineSec`. Any real
    /// completion or an activation resets the streak, so a window that becomes
    /// capturable again recovers on its next on-demand/activation capture.
    private func rescueStuckInFlightLocked(now: CFAbsoluteTime) {
        let timeout = schedule.inFlightTimeoutSec
        for (wid, var e) in entries where e.inFlight && (now - e.inFlightSince) > timeout {
            e.inFlight = false
            e.inFlightScheduleId = 0
            e.inFlightSince = 0
            e.timeoutStreak += 1
            let backoff: TimeInterval
            if e.timeoutStreak >= schedule.captureTimeoutQuarantineThreshold {
                e.quarantined = true
                backoff = schedule.captureQuarantineSec
                Diagnostics.log("THUMBQUAR", "wid=\(wid) quarantined after \(e.timeoutStreak) consecutive capture timeouts — suspending bg capture \(Int(schedule.captureQuarantineSec))s (window un-capturable; not re-hammering WindowServer)")
            } else {
                // 1s, 2s, 4s… capped at the quarantine ceiling.
                backoff = Swift.min(schedule.captureQuarantineSec, pow(2, Double(e.timeoutStreak - 1)))
            }
            generation &+= 1
            e.nextRefreshAt = now + backoff
            e.scheduleId = generation
            entries[wid] = e
            heap.push(HeapEntry(deadline: e.nextRefreshAt, wid: wid, scheduleId: generation))
        }
    }

    /// Pop tombstones off the heap head so `heap.peek()?.deadline` reflects
    /// an actual due time. A tombstone is a heap entry whose wid was
    /// unregistered, whose scheduleId no longer matches, or whose entry
    /// is in-flight (so should be skipped this tick).
    private func drainTombstonesLocked() {
        while let top = heap.peek() {
            guard entries[top.wid] != nil,
                  entries[top.wid]!.scheduleId == top.scheduleId,
                  !entries[top.wid]!.inFlight else {
                heap.pop()
                continue
            }
            return
        }
    }

    private struct HeapEntry: Comparable {
        let deadline: CFAbsoluteTime
        let wid: CGWindowID
        let scheduleId: UInt64
        static func < (lhs: HeapEntry, rhs: HeapEntry) -> Bool { lhs.deadline < rhs.deadline }
        static func == (lhs: HeapEntry, rhs: HeapEntry) -> Bool {
            lhs.deadline == rhs.deadline && lhs.wid == rhs.wid && lhs.scheduleId == rhs.scheduleId
        }
    }
}

/// Minimal binary min-heap. ~50 lines; avoids adding the Swift Collections
/// package dependency for this single use.
fileprivate struct MinHeap<Element: Comparable> {
    private var storage: [Element] = []
    var count: Int { storage.count }
    var isEmpty: Bool { storage.isEmpty }
    func peek() -> Element? { storage.first }

    mutating func push(_ value: Element) {
        storage.append(value)
        siftUp(storage.count - 1)
    }

    @discardableResult
    mutating func pop() -> Element? {
        guard !storage.isEmpty else { return nil }
        storage.swapAt(0, storage.count - 1)
        let value = storage.removeLast()
        if !storage.isEmpty { siftDown(0) }
        return value
    }

    private mutating func siftUp(_ start: Int) {
        var i = start
        while i > 0 {
            let parent = (i - 1) / 2
            if storage[i] < storage[parent] {
                storage.swapAt(i, parent)
                i = parent
            } else { return }
        }
    }

    private mutating func siftDown(_ start: Int) {
        var i = start
        let n = storage.count
        while true {
            let left = 2 * i + 1
            let right = 2 * i + 2
            var smallest = i
            if left < n, storage[left] < storage[smallest] { smallest = left }
            if right < n, storage[right] < storage[smallest] { smallest = right }
            if smallest == i { return }
            storage.swapAt(i, smallest)
            i = smallest
        }
    }
}
