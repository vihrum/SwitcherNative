import Foundation
import AppKit

public enum SupportedLanguage: String, CaseIterable {
    case english   = "en"
    case ukrainian = "uk"

    public var localeIdentifier: String {
        switch self {
        case .english:   return "en_US"
        case .ukrainian: return "uk_UA"
        }
    }

    public var displayName: String {
        switch self {
        case .english:   return "English"
        case .ukrainian: return "Українська"
        }
    }
}

public struct SwitchDecision {
    public let targetLanguage: SupportedLanguage
    public let convertedText:  String
}

public final class ThreeWayEngine {
    public static let shared = ThreeWayEngine()

    private let spellChecker = NSSpellChecker.shared
    private let lock = NSLock()

    // Resolved locale identifiers supported by the system
    private var resolvedUkLocale: String = "uk"
    private var resolvedEnLocale: String = "en"
    private var resolvedRuLocale: String = "ru"

    // In-memory cache to avoid repeated spell-check calls
    private var cache = [String: Bool]()
    private let cacheMaxSize = 1000

    private init() {
        resolveAvailableLanguages()

        // Pre-warm spell checker on a background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            _ = self.isValidWord("test", locale: self.resolvedEnLocale)
            _ = self.isValidWord("передумова", locale: self.resolvedUkLocale)
            _ = self.isValidWord("привет", locale: self.resolvedRuLocale)
        }
    }

    private func resolveAvailableLanguages() {
        let available = spellChecker.availableLanguages
        print("[ThreeWayEngine] Available spellcheck languages: \(available)")

        if let match = available.first(where: { $0 == "uk" || $0.hasPrefix("uk_") || $0.hasPrefix("uk-") }) {
            resolvedUkLocale = match
        }
        if let match = available.first(where: { $0 == "en" || $0 == "en_US" || $0.hasPrefix("en_") }) {
            resolvedEnLocale = match
        }
        if let match = available.first(where: { $0 == "ru" || $0.hasPrefix("ru_") || $0.hasPrefix("ru-") }) {
            resolvedRuLocale = match
        }
        print("[ThreeWayEngine] Active locales: EN=\(resolvedEnLocale), UK=\(resolvedUkLocale), RU=\(resolvedRuLocale)")
    }

    private static let commonTechWords: Set<String> = [
        "github", "gitlab", "bitbucket", "google", "youtube", "facebook", "meta",
        "instagram", "telegram", "whatsapp", "viber", "twitter", "tiktok", "linkedin",
        "chatgpt", "openai", "gemini", "claude", "apple", "microsoft", "amazon",
        "netflix", "spotify", "docker", "kubernetes", "linux", "macos", "ubuntu",
        "windows", "android", "ios", "swift", "python", "javascript", "typescript",
        "react", "vue", "angular", "node", "npm", "yarn", "rust", "golang",
        "figma", "slack", "zoom", "notion", "jira", "confluence", "trello",
        "online", "offline", "login", "logout", "signin", "signup", "email",
        "wifi", "bluetooth", "vpn", "proxy", "server", "client", "api", "json"
    ]

    // MARK: - Spell check with script safety check

    public func isValidWord(_ word: String, locale: String) -> Bool {
        guard !word.isEmpty else { return false }

        let lower = word.lowercased()
        if locale.hasPrefix("en") && ThreeWayEngine.commonTechWords.contains(lower) {
            return true
        }

        // Apple's spell checker returns valid=true for foreign scripts!
        let isEnLocale = locale.hasPrefix("en")
        if isEnLocale && !KeyMapping.isLatin(word) {
            return false
        }
        let isCyrillicLocale = locale.hasPrefix("uk") || locale.hasPrefix("ru")
        if isCyrillicLocale && !KeyMapping.isCyrillic(word) {
            return false
        }

        let normalizedWord = word.replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "ʼ", with: "'")
        let cacheKey = "\(normalizedWord)|\(locale)"

        lock.lock()
        if let cached = cache[cacheKey] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let range = spellChecker.checkSpelling(
            of: normalizedWord,
            startingAt: 0,
            language: locale,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        let valid = (range.location == NSNotFound)

        lock.lock()
        if cache.count >= cacheMaxSize {
            // Batch purge oldest 25% of entries to avoid per-word eviction overhead
            let toRemove = Array(cache.keys.prefix(cacheMaxSize / 4))
            for k in toRemove { cache.removeValue(forKey: k) }
        }
        cache[cacheKey] = valid
        lock.unlock()

        return valid
    }

    // MARK: - Auto-switch evaluation based on characters and dictionary

    /// Returns a conversion decision if the word is in the wrong layout, otherwise nil.
    public func evaluateWord(_ word: String, currentLanguage: SupportedLanguage) -> SwitchDecision? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }

        // User-defined excluded words check
        if SettingsManager.shared.isWordExcluded(trimmed) {
            return nil
        }
        let enEquiv = KeyMapping.uaToEn(trimmed)
        let uaEquiv = KeyMapping.enToUa(trimmed)
        if SettingsManager.shared.isWordExcluded(enEquiv) || SettingsManager.shared.isWordExcluded(uaEquiv) {
            return nil
        }

        // Skip words with numbers or strange characters, but allow all keys that correspond to letters in both layouts
        guard trimmed.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "-" || $0 == "’" || $0 == "ʼ" || KeyMapping.enToUaMap[$0] != nil || KeyMapping.uaToEnMap[$0] != nil }) else {
            return nil
        }

        // 1. Text is typed in Latin characters (e.g. "gthtlevjdf")
        if KeyMapping.isLatin(trimmed) {
            // If current language is English and this is a valid English word, don't switch
            if currentLanguage == .english && isValidWord(trimmed, locale: resolvedEnLocale) {
                return nil
            }
            // Even if current layout was Ukrainian, check if it's valid English
            if isValidWord(trimmed, locale: resolvedEnLocale) {
                return nil
            }

            // Convert to Ukrainian
            let uaCandidate = KeyMapping.enToUa(trimmed)
            if isValidWord(uaCandidate, locale: resolvedUkLocale) || isValidWord(uaCandidate, locale: resolvedRuLocale) {
                return SwitchDecision(targetLanguage: .ukrainian, convertedText: uaCandidate)
            }
            return nil
        }

        // 2. Text is typed in Cyrillic characters (e.g. "руддщ")
        if KeyMapping.isCyrillic(trimmed) {
            // If current language is Ukrainian and word is valid, don't switch
            if currentLanguage == .ukrainian && (isValidWord(trimmed, locale: resolvedUkLocale) || isValidWord(trimmed, locale: resolvedRuLocale)) {
                return nil
            }
            // Even if current layout was English, check if it's already valid in Ukrainian/Russian
            if isValidWord(trimmed, locale: resolvedUkLocale) || isValidWord(trimmed, locale: resolvedRuLocale) {
                return nil
            }

            // Convert to English
            let enCandidate = KeyMapping.uaToEn(trimmed)
            if isValidWord(enCandidate, locale: resolvedEnLocale) {
                return SwitchDecision(targetLanguage: .english, convertedText: enCandidate)
            }
            return nil
        }

        return nil
    }

    // MARK: - Hotkey conversion (instant script toggling)

    public func cycleText(_ text: String, currentLanguage: SupportedLanguage) -> SwitchDecision {
        if KeyMapping.isLatin(text) {
            return SwitchDecision(targetLanguage: .ukrainian, convertedText: KeyMapping.enToUa(text))
        } else {
            return SwitchDecision(targetLanguage: .english, convertedText: KeyMapping.uaToEn(text))
        }
    }
}
