import Cocoa

/// Window groups: a shortcut whose `windowGroupAttribute<N>` names an attribute shows only the windows
/// that share that attribute's value with the window in front when the shortcut was pressed (e.g. the
/// terminal windows on the same machine). AltTab derives no attribute itself: other tools write them
/// to the JSON files listed in `windowAttributesFiles`, in this shape:
///
///     {"windows": {"<window id>": {"machine": "box-1", "project": ["A", "B"]}}}
///
/// A value is a string or a list of strings; a window is in a group when any of its values is the
/// group's, and the front window's group is its first value. A window without the attribute is in no
/// group. When the front window has none, the shortcut is not grouped and shows what its other
/// settings say (e.g. the active app's windows).
struct WindowGroup: Equatable {
    let attribute: String
    let value: String
    let members: Set<CGWindowID>
}

enum WindowGroups {
    /// Window id -> attribute -> values.
    typealias Table = [CGWindowID: [String: [String]]]

    /// The group of the session in progress, set when a session starts (`begin`); nil when the
    /// shortcut is not grouped.
    private(set) static var current: WindowGroup?

    /// Main thread, when a session starts: the group of `sourceWid` (the window in front) for the
    /// shortcut's attribute, if it has one.
    static func begin(_ shortcutIndex: Int, _ sourceWid: CGWindowID?) {
        let attribute = RuntimeFlags.windowGroupAttribute(shortcutIndex)
        guard !attribute.isEmpty else {
            current = nil
            return
        }
        current = group(attribute, anchor: sourceWid, in: AttributeFiles.table())
        Diagnostics.log("GROUP", current.map { "shortcut \(shortcutIndex + 1): \(attribute)=\($0.value), \($0.members.count) windows" }
            ?? "shortcut \(shortcutIndex + 1): window #\(sourceWid ?? 0) has no \(attribute); not grouped")
    }

    /// Whether `window` is shown by the session's group (always, when the session is not grouped).
    static func admits(_ wid: CGWindowID?) -> Bool {
        guard let current else { return true }
        return wid.map { current.members.contains($0) } ?? false
    }

    static func group(_ attribute: String, anchor wid: CGWindowID?, in table: Table) -> WindowGroup? {
        guard !attribute.isEmpty, let wid, let value = table[wid]?[attribute]?.first else { return nil }
        let members = Set(table.compactMap { $0.value[attribute]?.contains(value) == true ? $0.key : nil })
        return WindowGroup(attribute: attribute, value: value, members: members)
    }

    /// One attributes file. Malformed entries are skipped; numbers are read as their decimal text.
    static func parse(_ data: Data) -> Table {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let windows = root["windows"] as? [String: Any] else { return [:] }
        var table = Table()
        for (key, value) in windows {
            guard let wid = CGWindowID(key), let attributes = value as? [String: Any] else { continue }
            var parsed = [String: [String]]()
            for (name, raw) in attributes {
                let values = ((raw as? [Any]) ?? [raw]).compactMap(text).filter { !$0.isEmpty }
                if !values.isEmpty { parsed[name] = values }
            }
            if !parsed.isEmpty { table[wid] = parsed }
        }
        return table
    }

    /// Several files' tables: a later file's values replace an earlier one's for the same window and attribute.
    static func merge(_ tables: [Table]) -> Table {
        tables.reduce(into: Table()) { merged, table in
            for (wid, attributes) in table {
                merged[wid, default: [:]].merge(attributes) { _, later in later }
            }
        }
    }

    private static func text(_ raw: Any) -> String? {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.stringValue }
        return nil
    }

    /// The files of `windowAttributesFiles`, read again only when one changed (size or modification time).
    enum AttributeFiles {
        private static var stamps = [String]()
        private static var cached = Table()

        static func table() -> Table {
            let paths = RuntimeFlags.windowAttributesFiles.map { NSString(string: $0).expandingTildeInPath }
            let now = paths.map(stamp)
            guard now != stamps else { return cached }
            cached = merge(paths.map { path in FileManager.default.contents(atPath: path).map(parse) ?? [:] })
            stamps = now
            return cached
        }

        private static func stamp(_ path: String) -> String {
            guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return path + "|missing" }
            let modified = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(path)|\(a[.size] ?? 0)|\(modified)"
        }
    }
}
