import XCTest

final class ForeignCaptureDetectorTests: XCTestCase {
    private var detector = ForeignCaptureDetector()
    private var now = 1000.0

    /// Feeds one sample `dt` seconds after the previous one.
    @discardableResult
    private func sample(_ watcher: Bool, after dt: Double = 0.5, ownInFlight: Bool = false, ownEndedAgo: Double = 100) -> ForeignCaptureDetector.Change {
        now += dt
        return detector.observe(watcherPresent: watcher, ownInFlight: ownInFlight, ownLastEndedAt: now - ownEndedAgo, now: now)
    }

    func testIdleStaysInactive() throws {
        for _ in 0..<20 { XCTAssertEqual(sample(false), .none) }
        XCTAssertFalse(detector.active)
    }

    func testSustainedWatcherEngagesAfterConfirmTime() throws {
        XCTAssertEqual(sample(true), .none)
        XCTAssertEqual(sample(true), .none)
        XCTAssertFalse(detector.active)
        XCTAssertEqual(sample(true), .engaged)
        XCTAssertTrue(detector.active)
        XCTAssertEqual(sample(true), .none)
    }

    func testBlipsBetweenFalseSamplesNeverEngage() throws {
        for _ in 0..<20 {
            sample(true)
            sample(false)
        }
        XCTAssertFalse(detector.active)
    }

    func testOwnCapturesNeverEngage() throws {
        for _ in 0..<20 { XCTAssertEqual(sample(true, ownInFlight: true), .none) }
        for _ in 0..<20 { XCTAssertEqual(sample(true, ownEndedAgo: 0.05), .none) }
        XCTAssertFalse(detector.active)
    }

    func testOwnCaptureSamplesAreIgnoredNotCountedAsFalse() throws {
        sample(true)
        sample(true, ownInFlight: true)
        XCTAssertEqual(sample(true), .engaged)
    }

    func testStaleRunDoesNotConfirmAfterALongGap() throws {
        sample(true)
        XCTAssertEqual(sample(true, after: 3600), .none)
        XCTAssertFalse(detector.active)
        XCTAssertEqual(sample(true), .none)
        XCTAssertEqual(sample(true), .engaged)
    }

    func testReleasesOnlyAfterReleaseTimeOfFalseSamples() throws {
        sample(true); sample(true); sample(true)
        XCTAssertTrue(detector.active)
        for _ in 0..<5 { XCTAssertEqual(sample(false), .none) }
        XCTAssertTrue(detector.active)
        XCTAssertEqual(sample(false), .released)
        XCTAssertFalse(detector.active)
    }

    func testAnInterruptionShorterThanReleaseKeepsItActive() throws {
        sample(true); sample(true); sample(true)
        sample(false); sample(false)
        XCTAssertEqual(sample(true), .none)
        XCTAssertTrue(detector.active)
        for _ in 0..<5 { sample(false) }
        XCTAssertTrue(detector.active)
        XCTAssertEqual(sample(false), .released)
    }

    func testLongGapThenFalseReleasesImmediately() throws {
        sample(true); sample(true); sample(true)
        XCTAssertEqual(sample(false, after: 7200), .released)
    }

    func testResetClearsEverything() throws {
        sample(true); sample(true); sample(true)
        detector.reset()
        XCTAssertFalse(detector.active)
        XCTAssertEqual(sample(true), .none)
    }
}
