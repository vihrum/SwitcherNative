import Foundation
import Carbon

public final class LayoutManager {
    public static let shared = LayoutManager()

    private var cachedSources: [TISInputSource]?
    private let lock = NSLock()

    private init() {
        // Invalidate cache when enabled sources change
        let enabledName = Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)
        DistributedNotificationCenter.default().addObserver(
            forName: enabledName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.lock.lock()
            self?.cachedSources = nil
            self?.lock.unlock()
        }
    }

    /// Returns all enabled keyboard sources (both KeyboardLayout and InputMode)
    public func installedKeyboardSources() -> [TISInputSource] {
        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedSources {
            return cached
        }

        var all: [TISInputSource] = []

        // KeyboardLayout type
        let propsLayout: [CFString: Any] = [
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout as Any,
            kTISPropertyInputSourceIsEnabled: true as Any
        ]
        if let list = TISCreateInputSourceList(propsLayout as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] {
            all += list
        }

        // InputMode type (used by some layouts on macOS 13+)
        let propsMode: [CFString: Any] = [
            kTISPropertyInputSourceType: kTISTypeKeyboardInputMode as Any,
            kTISPropertyInputSourceIsEnabled: true as Any
        ]
        if let list = TISCreateInputSourceList(propsMode as CFDictionary, false)?
            .takeRetainedValue() as? [TISInputSource] {
            all += list
        }

        // Deduplicate by sourceID
        var seen = Set<String>()
        let deduped = all.filter { src in
            guard let rawID = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else {
                return true
            }
            let id = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
            return seen.insert(id).inserted
        }

        cachedSources = deduped
        print("[LayoutManager] Found \(deduped.count) keyboard sources:")
        for src in deduped {
            if let raw = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
                print("  - \(id) -> \(language(for: src).displayName)")
            }
        }
        return deduped
    }

    public func currentInputSource() -> TISInputSource? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        return source
    }

    public func currentLanguage() -> SupportedLanguage {
        guard let source = currentInputSource() else {
            return .english
        }
        return language(for: source)
    }

    public func language(for source: TISInputSource) -> SupportedLanguage {
        guard let rawLanguages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return .english
        }
        let languages = Unmanaged<CFArray>.fromOpaque(rawLanguages).takeUnretainedValue() as? [String] ?? []
        for lang in languages {
            let lower = lang.lowercased()
            if lower.hasPrefix("uk") || lower.hasPrefix("ua") {
                return .ukrainian
            } else if lower.hasPrefix("en") {
                return .english
            }
        }
        // Fallback: check source ID
        if let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let id = Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
            if id.lowercased().contains("ukrainian") || id.lowercased().contains("uk.") {
                return .ukrainian
            }
        }
        return .english
    }

    public func switchTo(language: SupportedLanguage) {
        let sources = installedKeyboardSources()
        guard !sources.isEmpty else {
            print("[LayoutManager] ERROR: No keyboard sources found!")
            return
        }
        for source in sources {
            if self.language(for: source) == language {
                let result = TISSelectInputSource(source)
                print("[LayoutManager] Switched to \(language.displayName), result=\(result)")
                return
            }
        }
        print("[LayoutManager] WARNING: No source found for language \(language.displayName)")
    }

    public func toggleLanguage() -> SupportedLanguage {
        let current = currentLanguage()
        let next: SupportedLanguage = (current == .english) ? .ukrainian : .english
        switchTo(language: next)
        return next
    }
}
