import XCTest

final class WindowGroupsTests: XCTestCase {
    private func table(_ json: String) -> WindowGroups.Table {
        WindowGroups.parse(json.data(using: .utf8)!)
    }

    func testParseReadsStringsListsAndNumbers() throws {
        let t = table(#"{"windows": {"10": {"machine": "box-1", "project": ["A", "B"], "desktop": 2},"#
            + #" "11": {"machine": "", "flag": true}, "x": {"machine": "box-2"}, "12": "box-3"}}"#)
        XCTAssertEqual(t, [10: ["machine": ["box-1"], "project": ["A", "B"], "desktop": ["2"]]])
    }

    func testParseOfMalformedFilesIsEmpty() throws {
        XCTAssertEqual(table("not json"), [:])
        XCTAssertEqual(table(#"{"windows": []}"#), [:])
        XCTAssertEqual(table(#"[1, 2]"#), [:])
    }

    func testLaterFilesWinPerWindowAndAttribute() throws {
        let merged = WindowGroups.merge([
            [10: ["machine": ["box-1"], "project": ["A"]]],
            [10: ["project": ["B"]], 11: ["machine": ["box-2"]]],
        ])
        XCTAssertEqual(merged, [10: ["machine": ["box-1"], "project": ["B"]], 11: ["machine": ["box-2"]]])
    }

    func testGroupIsEveryWindowSharingTheFrontWindowsFirstValue() throws {
        let t: WindowGroups.Table = [
            10: ["machine": ["box-1"]],
            11: ["machine": ["box-1"]],
            12: ["machine": ["box-2"]],
            13: ["project": ["A"]],
            14: ["machine": ["box-2", "box-1"]],
        ]
        XCTAssertEqual(WindowGroups.group("machine", anchor: 10, in: t), WindowGroup(attribute: "machine", value: "box-1", members: [10, 11, 14]))
        XCTAssertEqual(WindowGroups.group("machine", anchor: 14, in: t)?.members, [12, 14])
    }

    func testNoGroupWithoutAnAttributeOrAFrontWindowValue() throws {
        let t: WindowGroups.Table = [10: ["machine": ["box-1"]], 13: ["project": ["A"]]]
        XCTAssertNil(WindowGroups.group("", anchor: 10, in: t))
        XCTAssertNil(WindowGroups.group("machine", anchor: 13, in: t))
        XCTAssertNil(WindowGroups.group("machine", anchor: 99, in: t))
        XCTAssertNil(WindowGroups.group("machine", anchor: nil, in: t))
    }
}
