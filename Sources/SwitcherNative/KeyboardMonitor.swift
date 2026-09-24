import Foundation
import AppKit
import Carbon

public final class KeyboardMonitor {
    public static let shared = KeyboardMonitor()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Word tracking — accessed ONLY from main thread (CGEventTap runs on main RunLoop)
    private var currentWordBuffer = ""
    private var lastCompletedWord = ""
    private var lastDelimiter = ""
    private var lastCompletedWordTimestamp: TimeInterval = 0

    // Left Command tracking
    private var leftCmdDownTimestamp: TimeInterval = 0
    private var leftCmdAlone = false
    private var lastLeftCmdReleaseTimestamp: TimeInterval = 0

    // Double-modifier tracking (Option / Shift)
    private var lastModifierTimestamp: TimeInterval = 0
    private var lastModifierKeyCode: CGKeyCode = 0

    // Excluded bundle IDs — cached on main thread, refreshed on app switch
    private var cachedFrontBundle: String? = nil
    private var isFrontAppExcluded = false

    private init() {
        // Update exclusion cache whenever the frontmost app changes
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            self?.cachedFrontBundle = id
            self?.isFrontAppExcluded = id.map { SettingsManager.shared.isAppExcluded($0) } ?? false
        }
    }

    // MARK: - Start / Stop

    public func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) |
                                (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon -> Unmanaged<CGEvent>? in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handleEvent(type: type, event: event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            print("[KeyboardMonitor] Failed to create CGEventTap — check Accessibility permission.")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[KeyboardMonitor] Event tap started.")
        return true
    }

    public func stop() {
        guard let tap = eventTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        eventTap = nil
        print("[KeyboardMonitor] Event tap stopped.")
    }

    // Global barrier flag: true when TextReplacer is actively deleting and typing
    public static var isReplacing = false

    // MARK: - Core event handler (called on main RunLoop)

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if system disabled it
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        // Absolute barrier: while TextReplacer is modifying text, ignore all events completely
        if KeyboardMonitor.isReplacing {
            return Unmanaged.passUnretained(event)
        }

        // Skip synthetic events we generated (backup check)
        if event.getIntegerValueField(.eventSourceUserData) == kSyntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        // Pause in password fields
        if IsSecureEventInputEnabled() {
            resetWordState()
            return Unmanaged.passUnretained(event)
        }

        // Pause in excluded apps (cached — no AppKit call per event)
        if isFrontAppExcluded {
            resetWordState()
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .flagsChanged: handleFlagsChanged(event: event)
        case .keyDown:      handleKeyDown(event: event)
        default: break
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Modifier key handler

    private func handleFlagsChanged(event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags   = event.flags
        let now     = CACurrentMediaTime()           // faster than Date()
        let mode    = SettingsManager.shared.hotkeyMode

        // ── Left Command (keyCode 55) ──────────────────────────────────────
        if keyCode == 55 {
            let isDown = flags.contains(.maskCommand)
            if isDown {
                leftCmdDownTimestamp = now
                leftCmdAlone = true
            } else {
                defer {
                    leftCmdAlone = false
                    leftCmdDownTimestamp = 0
                }
                guard leftCmdAlone else { return }
                let duration = now - leftCmdDownTimestamp
                guard duration > 0.01 && duration < 0.65 else { return }

                switch mode {
                case .leftCommand:
                    triggerForceSwitchAndConvert()
                case .doubleCommand:
                    let gap = now - lastLeftCmdReleaseTimestamp
                    if gap < 0.4 {
                        triggerForceSwitchAndConvert()
                        lastLeftCmdReleaseTimestamp = 0
                    } else {
                        lastLeftCmdReleaseTimestamp = now
                    }
                default:
                    break
                }
            }
            return
        }

        // ── Option keys (58 = left, 61 = right) ────────────────────────────
        if (keyCode == 58 || keyCode == 61), mode == .doubleOption {
            // Option press cancels leftCmdAlone (Option can co-occur with Cmd)
            leftCmdAlone = false
            if flags.contains(.maskAlternate) {
                let gap = now - lastModifierTimestamp
                if gap < 0.4 && lastModifierKeyCode == keyCode {
                    triggerForceSwitchAndConvert()
                    lastModifierTimestamp = 0
                } else {
                    lastModifierTimestamp = now
                    lastModifierKeyCode   = keyCode
                }
            }
            return
        }

        // ── Shift keys (56 = left, 60 = right) ─────────────────────────────
        if (keyCode == 56 || keyCode == 60), mode == .doubleShift {
            leftCmdAlone = false
            if flags.contains(.maskShift) {
                let gap = now - lastModifierTimestamp
                if gap < 0.4 && lastModifierKeyCode == keyCode {
                    triggerForceSwitchAndConvert()
                    lastModifierTimestamp = 0
                } else {
                    lastModifierTimestamp = now
                    lastModifierKeyCode   = keyCode
                }
            }
            return
        }

        // Any OTHER modifier pressed → not a solo Command tap
        if keyCode != 55 {
            leftCmdAlone = false
        }
    }

    // MARK: - Key down handler

    private func handleKeyDown(event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags   = event.flags

        // Cmd+anything = shortcut, cancel solo Cmd tap
        if flags.contains(.maskCommand) {
            leftCmdAlone = false
            currentWordBuffer = ""
            return
        }

        // Option+anything = special character (e.g. Russian via Option in UA layout),
        // still append to buffer but don't cancel leftCmdAlone
        // (Option alone sets leftCmdAlone = false already in flagsChanged)

        // F12 / Pause-Break dedicated hotkey
        if SettingsManager.shared.hotkeyMode == .f12OrBreak && (keyCode == 111 || keyCode == 0x71) {
            triggerForceSwitchAndConvert()
            return
        }

        // Backspace (51)
        if keyCode == 51 {
            if !currentWordBuffer.isEmpty {
                currentWordBuffer.removeLast()
            } else if !lastCompletedWord.isEmpty {
                // User deleted the delimiter after last word — reactivate it
                lastCompletedWord.removeLast()
                if lastCompletedWord.isEmpty {
                    lastCompletedWord = ""
                    lastDelimiter = ""
                }
            }
            return
        }

        // Escape (53) — clear everything
        if keyCode == 53 {
            resetWordState()
            return
        }

        // Navigation / cursor keys — clear buffer without resetting lastCompleted
        if keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126 {  // ← → ↓ ↑
            currentWordBuffer = ""
            return
        }
        if keyCode == 115 || keyCode == 119 || keyCode == 116 || keyCode == 121 { // Home/End/PgUp/PgDn
            resetWordState()
            return
        }

        // Extract typed Unicode character
        var length = 0
        var chars  = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)
        guard length > 0, let scalar = UnicodeScalar(chars[0]) else { return }
        let char = Character(scalar)

        // Keys that represent letters in Ukrainian layout even if ASCII punctuation:
        // '[' -> х, ']' -> ї, ';' -> ж, '\'' -> є, ',' -> б, '.' -> ю, '`' -> '
        let isLetterKeyInUa = (char == "'" || char == "[" || char == "]" || char == ";" ||
                               char == "," || char == "." || char == "/" || char == "`" ||
                               char == "’" || char == "«" || char == "»")

        let isDelimiter = (keyCode == 49)   // space
                       || (keyCode == 36)   // return
                       || (keyCode == 48)   // tab
                       || char.isWhitespace
                       || (!isLetterKeyInUa && (char.isPunctuation || char.isSymbol))

        if isDelimiter {
            if !currentWordBuffer.isEmpty {
                let word = currentWordBuffer
                lastCompletedWord      = word
                lastDelimiter          = String(char)
                lastCompletedWordTimestamp = CACurrentMediaTime()

                if SettingsManager.shared.autoSwitchEnabled {
                    checkAndAutoSwitch(word: word, delimiter: String(char))
                }
                currentWordBuffer = ""
            }
        } else {
            currentWordBuffer.append(char)
            // Safety cap — shouldn't happen but prevents unbounded growth
            if currentWordBuffer.count > 80 {
                currentWordBuffer = String(currentWordBuffer.suffix(80))
            }
        }
    }

    // MARK: - Auto-switch on completed word

    private func checkAndAutoSwitch(word: String, delimiter: String) {
        let currentLang = LayoutManager.shared.currentLanguage()

        guard let decision = ThreeWayEngine.shared.evaluateWord(word, currentLanguage: currentLang) else {
            return
        }

        // +1 for the delimiter character
        let backspaceCount = word.count + 1
        let replacementText = decision.convertedText + delimiter

        TextReplacer.shared.replaceLastWord(
            backspaceCount: backspaceCount,
            newText: replacementText,
            targetLanguage: decision.targetLanguage
        )

        // Update buffer so hotkey-based correction still works correctly
        lastCompletedWord = decision.convertedText
    }

    // Debounce to prevent key bounce or accidental double triggering within milliseconds
    private var lastForceSwitchTimestamp: TimeInterval = 0

    // MARK: - Force switch (Left Command hotkey)

    public func triggerForceSwitchAndConvert() {
        let now = CACurrentMediaTime()
        guard now - lastForceSwitchTimestamp > 0.28 else { return }
        lastForceSwitchTimestamp = now

        let currentLang = LayoutManager.shared.currentLanguage()

        // 1. Currently mid-word in buffer
        if !currentWordBuffer.isEmpty {
            let text = currentWordBuffer
            let decision = ThreeWayEngine.shared.cycleText(text, currentLanguage: currentLang)
            
            // Allow repeated Command tap to undo/toggle back
            currentWordBuffer = ""
            lastCompletedWord = decision.convertedText
            lastDelimiter = ""
            lastCompletedWordTimestamp = CACurrentMediaTime()

            TextReplacer.shared.replaceLastWord(
                backspaceCount: text.count,
                newText: decision.convertedText,
                targetLanguage: decision.targetLanguage
            )
            return
        }

        // 2. Just finished a word (within last 8 seconds)
        if !lastCompletedWord.isEmpty && (now - lastCompletedWordTimestamp < 8.0) {
            let text  = lastCompletedWord
            let delim = lastDelimiter
            let decision = ThreeWayEngine.shared.cycleText(text, currentLanguage: currentLang)

            // Keep updated so repeated Command tap flips it back immediately
            lastCompletedWord = decision.convertedText
            lastCompletedWordTimestamp = now

            // backspaces = word chars + delimiter (if delimiter is non-empty and single char)
            let delimCount = delim.isEmpty ? 0 : 1
            TextReplacer.shared.replaceLastWord(
                backspaceCount: text.count + delimCount,
                newText: decision.convertedText + delim,
                targetLanguage: decision.targetLanguage
            )
            return
        }

        // 3. No word in buffer → simply toggle the input layout cleanly without touching clipboard
        _ = LayoutManager.shared.toggleLanguage()
    }

    // MARK: - Helpers

    private func resetWordState() {
        currentWordBuffer     = ""
        lastCompletedWord     = ""
        lastDelimiter         = ""
        lastCompletedWordTimestamp = 0
    }
}
