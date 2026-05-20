import Cocoa
import CoreGraphics
import Foundation

struct Args {
    var maxUserNotificationWindows = 1
    var topCount = 8
    var context = ""
    var marker = ""
    var logPath = "/tmp/alttab-run.log"
}

struct WindowRow {
    let wid: UInt32
    let pid: Int32
    let owner: String
}

func parseArgs() -> Args {
    var args = Args()
    var index = 1
    while index < CommandLine.arguments.count {
        let arg = CommandLine.arguments[index]
        let next = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : ""
        switch arg {
        case "--max-user-notification-windows":
            args.maxUserNotificationWindows = Int(next) ?? args.maxUserNotificationWindows; index += 1
        case "--top-count":
            args.topCount = Int(next) ?? args.topCount; index += 1
        case "--context":
            args.context = next; index += 1
        case "--marker":
            args.marker = next; index += 1
        case "--log":
            args.logPath = next; index += 1
        default:
            break
        }
        index += 1
    }
    return args
}

func visibleRows() -> [WindowRow] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return info.compactMap { row in
        guard (row[kCGWindowLayer as String] as? Int) == 0,
              let wid = row[kCGWindowNumber as String] as? UInt32,
              let pid = row[kCGWindowOwnerPID as String] as? Int32,
              let owner = row[kCGWindowOwnerName as String] as? String,
              let boundsDict = row[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              bounds.width >= 10,
              bounds.height >= 10,
              (row[kCGWindowAlpha as String] as? Double ?? 1.0) >= 0.05 else { return nil }
        return WindowRow(wid: wid, pid: pid, owner: owner)
    }
}

func appendLog(_ path: String, _ line: String) {
    guard let data = (line + "\n").data(using: .utf8) else { return }
    if FileManager.default.fileExists(atPath: path),
       let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path)) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: URL(fileURLWithPath: path))
    }
}

let args = parseArgs()
let rows = visibleRows()
let topRows = Array(rows.prefix(max(1, args.topCount)))
let notificationRows = rows.filter { $0.owner == "UserNotificationCenter" }
let topNotificationRows = topRows.filter { $0.owner == "UserNotificationCenter" }
let frontApp = NSWorkspace.shared.frontmostApplication
let frontName = frontApp?.localizedName ?? "?"
let frontPid = frontApp?.processIdentifier ?? -1
let topSummary = topRows.prefix(8).map { "\($0.owner)#\($0.wid)" }.joined(separator: ",")
let storm = notificationRows.count > args.maxUserNotificationWindows
let status = storm ? "POPUP_STORM" : "ok"
let markerPart = args.marker.isEmpty ? "" : " marker=\(args.marker)"
let contextPart = args.context.isEmpty ? "" : " context=\(args.context)"
let line = "popup-storm-guard status=\(status)\(markerPart)\(contextPart) userNotificationWindows=\(notificationRows.count) top\(args.topCount)=\(topNotificationRows.count) maxAllowed=\(args.maxUserNotificationWindows) front=\(frontName)#\(frontPid) top=[\(topSummary)]"
print(line)
if storm {
    appendLog(args.logPath, "=== EVAL ABORT POPUP STORM: \(line) ===")
    exit(86)
}
