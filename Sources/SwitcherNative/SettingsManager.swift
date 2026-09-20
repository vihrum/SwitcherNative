import Foundation

public enum HotkeyMode: String, CaseIterable {
    case leftCommand  = "leftCommand"
    case doubleCommand = "doubleCommand"
    case doubleOption  = "doubleOption"
    case doubleShift   = "doubleShift"
    case f12OrBreak    = "f12OrBreak"

    public var title: String {
        switch self {
        case .leftCommand:   return "Лівий Command ⌘ (одинарний тап)"
        case .doubleCommand: return "Подвійний лівий Command ⌘⌘"
        case .doubleOption:  return "Подвійний Option ⌥⌥"
        case .doubleShift:   return "Подвійний Shift ⇧⇧"
        case .f12OrBreak:    return "F12 / Pause Break"
        }
    }
}

public final class SettingsManager {
    public static let shared = SettingsManager()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let autoSwitch    = "kAutoSwitchEnabled"
        static let hotkeyMode    = "kHotkeyMode"
        static let excludedApps  = "kExcludedApps"
        static let excludedWords = "kExcludedWords"
    }

    private static let defaultExcludedApps = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "com.sublimetext.4",
        "io.alacritty",
        "com.panic.Nova"
    ]

    private init() {
        defaults.register(defaults: [
            Key.autoSwitch:    true,
            Key.hotkeyMode:    HotkeyMode.leftCommand.rawValue,
            Key.excludedApps:  SettingsManager.defaultExcludedApps,
            Key.excludedWords: [String]()
        ])
    }

    public var autoSwitchEnabled: Bool {
        get { defaults.bool(forKey: Key.autoSwitch) }
        set { defaults.set(newValue, forKey: Key.autoSwitch) }
    }

    public var hotkeyMode: HotkeyMode {
        get {
            let raw = defaults.string(forKey: Key.hotkeyMode) ?? HotkeyMode.leftCommand.rawValue
            return HotkeyMode(rawValue: raw) ?? .leftCommand
        }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkeyMode) }
    }

    public var excludedApps: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.excludedApps) ?? []) }
        set { defaults.set(Array(newValue), forKey: Key.excludedApps) }
    }

    public func isAppExcluded(_ bundleID: String) -> Bool {
        excludedApps.contains(bundleID)
    }

    // MARK: - Excluded Words

    public var excludedWords: [String] {
        get { (defaults.stringArray(forKey: Key.excludedWords) ?? []).sorted() }
        set { defaults.set(newValue, forKey: Key.excludedWords) }
    }

    public func addExcludedWord(_ raw: String) {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return }
        var current = Set(excludedWords)
        current.insert(clean)
        defaults.set(Array(current).sorted(), forKey: Key.excludedWords)
    }

    public func removeExcludedWord(_ raw: String) {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var current = Set(excludedWords)
        current.remove(clean)
        defaults.set(Array(current).sorted(), forKey: Key.excludedWords)
    }

    public func isWordExcluded(_ word: String) -> Bool {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return false }
        let current = Set(defaults.stringArray(forKey: Key.excludedWords) ?? [])
        return current.contains(clean)
    }
}
