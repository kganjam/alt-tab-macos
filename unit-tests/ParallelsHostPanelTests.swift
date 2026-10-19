import XCTest

/// REL-114: values measured live on 2026-10-18 (Parallels 27.0.3, macOS 27).
final class ParallelsHostPanelTests: XCTestCase {
    private let readOnly = 1
    private let readWrite = 2

    func testStuckLauncherPanelIsAHostPanel() throws {
        // AltTab's title for the untitled panel falls back to the app name
        XCTAssertTrue(ParallelsHostPanelTestable.isHostPanel(isCoherenceApp: true, title: "Outlook (classic)", appName: "Outlook (classic)", sharingState: readOnly))
        XCTAssertTrue(ParallelsHostPanelTestable.isHostPanel(isCoherenceApp: true, title: "", appName: "Outlook (classic)", sharingState: readOnly))
        XCTAssertTrue(ParallelsHostPanelTestable.isHostPanel(isCoherenceApp: true, title: nil, appName: "Outlook (classic)", sharingState: readOnly))
    }

    func testGuestWindowTitledLikeItsAppIsNotAHostPanel() throws {
        // the Windows Settings window is titled "Settings", like its Parallels app
        XCTAssertFalse(ParallelsHostPanelTestable.isHostPanel(isCoherenceApp: true, title: "Settings", appName: "Settings", sharingState: readWrite))
    }

    func testUntitledGuestWindowIsNotAHostPanel() throws {
        XCTAssertFalse(ParallelsHostPanelTestable.isHostPanel(isCoherenceApp: true, title: "", appName: "OneNote", sharingState: readWrite))
    }

    func testTitledWindowIsNeverAHostPanel() throws {
        XCTAssertFalse(ParallelsHostPanelTestable.isHostPanel(isCoherenceApp: true, title: "1. To Me - kganjam@outlook.com - Outlook", appName: "Outlook (classic)", sharingState: readOnly))
    }

    func testMacAppIsNeverAHostPanel() throws {
        XCTAssertFalse(ParallelsHostPanelTestable.isHostPanel(isCoherenceApp: false, title: "", appName: "Finder", sharingState: readOnly))
    }

    func testClosedWindowIsNotAHostPanel() throws {
        XCTAssertFalse(ParallelsHostPanelTestable.isHostPanel(isCoherenceApp: true, title: "", appName: "Outlook (classic)", sharingState: nil))
    }
}
