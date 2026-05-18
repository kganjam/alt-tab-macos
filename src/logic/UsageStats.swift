struct UsageStats {
    private static let defaults = UserDefaults(suiteName: "\(App.bundleIdentifier).usage")!
    private static let queue = DispatchQueue(label: "usageStats", qos: .utility)
    private static let maxAge: TimeInterval = 365 * 24 * 3600
    private static let allKeys = ["triggers", "searches", "triggersAppIcons", "triggersTitles", "triggersAutoSize", "triggersExtraShortcuts"]
    private(set) static var searchRecordedThisSession = false

    static func recordTrigger(_ shortcutIndex: Int) {
        var keys = ["triggers"]
        if shortcutIndex > 0 && shortcutIndex < Preferences.maxShortcutCount { keys.append("triggersExtraShortcuts") }
        if Preferences.appearanceStyle == .appIcons { keys.append("triggersAppIcons") }
        if Preferences.appearanceStyle == .titles { keys.append("triggersTitles") }
        if Preferences.appearanceSize == .auto { keys.append("triggersAutoSize") }
        record(keys)
    }

    static func recordSearchIfFirst() {
        guard !searchRecordedThisSession else { return }
        searchRecordedThisSession = true
        record(["searches"])
    }

    static func resetSession() {
        searchRecordedThisSession = false
    }

    static func count(_ key: String, since date: Date) -> Int {
        let threshold = Int(date.timeIntervalSince1970)
        return queue.sync {
            getTimestamps(key).count { $0 >= threshold }
        }
    }

    static func prune() {
        queue.async {
            let cutoff = Int(Date().timeIntervalSince1970 - maxAge)
            for key in allKeys {
                let timestamps = getTimestamps(key)
                guard !timestamps.isEmpty else { continue }
                let pruned = timestamps.filter { $0 >= cutoff }
                defaults.set(pruned, forKey: key)
            }
        }
    }

    private static func record(_ keys: [String]) {
        let timestamp = Int(Date().timeIntervalSince1970)
        queue.async {
            for key in keys {
                var timestamps = getTimestamps(key)
                timestamps.append(timestamp)
                defaults.set(timestamps, forKey: key)
            }
        }
    }

    private static func getTimestamps(_ key: String) -> [Int] {
        defaults.array(forKey: key) as? [Int] ?? []
    }
}
