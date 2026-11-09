import Foundation

/// Pure state machine behind `ScreenCaptureGuard`: decides, from a stream of samples of
/// WindowServer's "screen watcher present" byte, whether ANOTHER app is screen-capturing.
///
/// The byte (`CGSIsScreenWatcherPresent`, a shared-memory read) is true while any client holds a
/// ScreenCaptureKit / display stream. It is also true for ~20-40ms around each of OUR OWN
/// one-shot SCK screenshots (measured 2026-11-09, macOS 27.2: it rises ~20ms after the request,
/// falls ~10ms after the completion handler; the private CGSHWCaptureWindowList path never
/// raises it). A real recording holds it continuously (2119/2119 samples at 2ms over a 5s
/// SCStream; it dropped within 2ms of stopCapture). So a sample counts only when none of our
/// captures is in flight or just ended, and the byte must stay true for `confirmSec`.
struct ForeignCaptureDetector {
    /// How long the byte must stay true (own-capture samples excluded) before the capture counts.
    var confirmSec: Double = 1
    /// How long the byte must stay false before a detected capture is considered over.
    var releaseSec: Double = 3
    /// Samples this soon after one of our captures ended are ignored (the byte lags the completion).
    var ownGraceSec: Double = 0.15
    /// A pause between usable samples longer than this breaks a confirmation run.
    var maxGapSec: Double = 3

    enum Change { case none, engaged, released }

    private(set) var active = false
    private var runStart: Double?
    private var lastSampleAt = -Double.infinity
    private var lastForeignTrueAt = -Double.infinity

    mutating func observe(watcherPresent: Bool, ownInFlight: Bool, ownLastEndedAt: Double, now: Double) -> Change {
        guard !ownInFlight, now - ownLastEndedAt >= ownGraceSec else { return .none }
        if now - lastSampleAt > maxGapSec { runStart = nil }
        lastSampleAt = now
        guard watcherPresent else { return release(now) }
        lastForeignTrueAt = now
        let start = runStart ?? now
        runStart = start
        guard !active, now - start >= confirmSec else { return .none }
        active = true
        return .engaged
    }

    private mutating func release(_ now: Double) -> Change {
        runStart = nil
        guard active, now - lastForeignTrueAt >= releaseSec else { return .none }
        active = false
        return .released
    }

    mutating func reset() {
        active = false
        runStart = nil
        lastSampleAt = -.infinity
        lastForeignTrueAt = -.infinity
    }
}
