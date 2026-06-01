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
    }

    private struct Entry {
        var thumbnail: CALayerContents?
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
    }

    private let lock = NSLock()
    private var entries: [CGWindowID: Entry] = [:]
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
    func read(wid: CGWindowID) -> CALayerContents? {
        lock.lock(); defer { lock.unlock() }
        return entries[wid]?.thumbnail
    }

    func lastUpdatedAt(wid: CGWindowID) -> CFAbsoluteTime {
        lock.lock(); defer { lock.unlock() }
        return entries[wid]?.lastUpdatedAt ?? 0
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
    func writeCapture(wid: CGWindowID, image: CALayerContents, liveSurface: Bool = true) {
        lock.lock(); defer { lock.unlock() }
        guard entries[wid] != nil else { return }
        var e = entries[wid]!
        e.thumbnail = image
        e.isLiveSurface = liveSurface
        e.lastUpdatedAt = CFAbsoluteTimeGetCurrent()
        let wasBgInitiated = e.inFlight
        let poppedScheduleId = e.inFlightScheduleId
        e.inFlight = false
        e.inFlightScheduleId = 0
        e.inFlightSince = 0
        entries[wid] = e
        guard wasBgInitiated, e.scheduleId == poppedScheduleId else { return }
        // Push the next BG deadline.
        let now = CFAbsoluteTimeGetCurrent()
        let (interval, jitter) = intervalAndJitter(e.tier)
        let deadline = now + interval + Double.random(in: -jitter...jitter)
        generation &+= 1
        e.nextRefreshAt = deadline
        e.scheduleId = generation
        entries[wid] = e
        heap.push(HeapEntry(deadline: deadline, wid: wid, scheduleId: generation))
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
        entries[wid] = e
        guard e.scheduleId == poppedScheduleId else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let (interval, _) = intervalAndJitter(e.tier)
        generation &+= 1
        e.nextRefreshAt = now + interval
        e.scheduleId = generation
        entries[wid] = e
        heap.push(HeapEntry(deadline: e.nextRefreshAt, wid: wid, scheduleId: generation))
    }

    /// Move a window's next refresh earlier. No-op if the requested
    /// deadline is later than (or equal to) the current schedule.
    func bumpUp(wid: CGWindowID, to requestedDeadline: CFAbsoluteTime) {
        lock.lock(); defer { lock.unlock() }
        guard entries[wid] != nil else { return }
        var e = entries[wid]!
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
        entries[wid]!.thumbnail = nil
        entries[wid]!.isLiveSurface = false
        entries[wid]!.lastUpdatedAt = 0
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
        var liveSurfaces = 0, detached = 0
        for (_, e) in entries {
            switch e.tier { case .hot: hot += 1; case .warm: warm += 1; case .cold: cold += 1 }
            if e.inFlight { inFlight += 1 }
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
        return "entries=\(entries.count) liveSurfaces=\(liveSurfaces) detached=\(detached) surfaces=\(surfaces) pixelBuffer=\(pixelBuffer) cgImage=\(cgImage) hot=\(hot) warm=\(warm) cold=\(cold) inFlight=\(inFlight) heap=\(heap.count) nextDueMs=\(nextDueMs)"
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

    /// Reset entries whose in-flight capture leaked. Forces a new heap
    /// entry at now+1s so they're retried promptly. Cheap; runs once
    /// per tick.
    private func rescueStuckInFlightLocked(now: CFAbsoluteTime) {
        let timeout = schedule.inFlightTimeoutSec
        for (wid, var e) in entries where e.inFlight && (now - e.inFlightSince) > timeout {
            e.inFlight = false
            e.inFlightScheduleId = 0
            e.inFlightSince = 0
            generation &+= 1
            e.nextRefreshAt = now + 1
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
