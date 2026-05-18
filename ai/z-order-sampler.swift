import Cocoa
import CoreGraphics
import Foundation

struct Args {
    var targetWid: UInt32 = 0
    var targetPid: Int32 = 0
    var durationMs = 2500
    var intervalMs = 5
}

struct Row {
    let wid: UInt32
    let pid: Int32
    let owner: String
}

let blocklistedOwners: Set<String> = [
    "Window Server", "Control Center", "Dock", "AltTab", "Notification Center",
    "SystemUIServer", "Spotlight", "Menubar", "Wallpaper", "CursorUIViewService",
    "LocalAuthenticationRemoteService",
]

func parseArgs() -> Args {
    var args = Args()
    var i = 1
    while i < CommandLine.arguments.count {
        let arg = CommandLine.arguments[i]
        let next = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : ""
        switch arg {
        case "--target-wid": args.targetWid = UInt32(next) ?? 0; i += 1
        case "--target-pid": args.targetPid = Int32(next) ?? 0; i += 1
        case "--duration-ms": args.durationMs = Int(next) ?? args.durationMs; i += 1
        case "--interval-ms": args.intervalMs = Int(next) ?? args.intervalMs; i += 1
        default: break
        }
        i += 1
    }
    return args
}

func jsonString(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

func numberOrNull(_ value: Int?) -> String {
    value.map(String.init) ?? "null"
}

func visibleRows() -> (raw: [Row], app: [Row]) {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return ([], []) }
    let raw = info.compactMap { row -> Row? in
        guard (row[kCGWindowLayer as String] as? Int) == 0,
              let wid = row[kCGWindowNumber as String] as? UInt32,
              let pid = row[kCGWindowOwnerPID as String] as? Int32,
              let owner = row[kCGWindowOwnerName as String] as? String,
              let boundsDict = row[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
              bounds.width >= 20,
              bounds.height >= 20,
              (row[kCGWindowAlpha as String] as? Double ?? 1.0) >= 0.05 else { return nil }
        return Row(wid: wid, pid: pid, owner: owner)
    }
    return (raw, raw.filter { !blocklistedOwners.contains($0.owner) })
}

let args = parseArgs()
let started = DispatchTime.now().uptimeNanoseconds
let durationNs = UInt64(max(1, args.durationMs)) * 1_000_000
let intervalUs = useconds_t(max(1, args.intervalMs) * 1000)

while true {
    let now = DispatchTime.now().uptimeNanoseconds
    let elapsedNs = now - started
    if elapsedNs > durationNs { break }
    let rows = visibleRows()
    let targetPid = args.targetPid != 0 ? args.targetPid : (rows.app.first { $0.wid == args.targetWid }?.pid ?? 0)
    let targetZ = rows.app.firstIndex { $0.wid == args.targetWid }
    let above = targetZ.map { Array(rows.app.prefix($0)) } ?? rows.app
    let sameAbove = targetPid == 0 ? [] : above.filter { $0.pid == targetPid && $0.wid != args.targetWid }
    let sameTop8 = targetPid == 0 ? 0 : rows.app.prefix(8).filter { $0.pid == targetPid }.count
    let rawTop = rows.raw.first
    let appTop = rows.app.first
    let topRows = Array(rows.app.prefix(16))
    let front = NSWorkspace.shared.frontmostApplication
    let parts = [
        "\"t_ms\":\(String(format: "%.3f", Double(elapsedNs) / 1_000_000.0))",
        "\"front_pid\":\(front?.processIdentifier ?? 0)",
        "\"front_name\":\(jsonString(front?.localizedName ?? ""))",
        "\"raw_top_wid\":\(rawTop.map { String($0.wid) } ?? "null")",
        "\"raw_top_pid\":\(rawTop.map { String($0.pid) } ?? "null")",
        "\"raw_top_owner\":\(jsonString(rawTop?.owner ?? ""))",
        "\"top_wid\":\(appTop.map { String($0.wid) } ?? "null")",
        "\"top_pid\":\(appTop.map { String($0.pid) } ?? "null")",
        "\"top_owner\":\(jsonString(appTop?.owner ?? ""))",
        "\"target_wid\":\(args.targetWid)",
        "\"target_pid\":\(targetPid)",
        "\"target_z\":\(numberOrNull(targetZ))",
        "\"same_app_above\":\(sameAbove.count)",
        "\"same_app_top8\":\(sameTop8)",
        "\"same_app_above_wids\":[\(sameAbove.prefix(8).map { String($0.wid) }.joined(separator: ","))]",
        "\"top_wids\":[\(topRows.map { String($0.wid) }.joined(separator: ","))]",
        "\"top_pids\":[\(topRows.map { String($0.pid) }.joined(separator: ","))]",
        "\"top_owners\":[\(topRows.map { jsonString($0.owner) }.joined(separator: ","))]",
    ]
    print("{\(parts.joined(separator: ","))}")
    fflush(stdout)
    usleep(intervalUs)
}
