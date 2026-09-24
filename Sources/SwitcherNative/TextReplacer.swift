import Foundation
import AppKit
import Carbon

// Unique marker so our own CGEventTap ignores synthetic events
let kSyntheticEventMarker: Int64 = 0x5357_4954_4348  // "SWITCH"

public final class TextReplacer {
    public static let shared = TextReplacer()

    // Use hidSystemState so synthetic events are clean and not mixed with session state
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    private init() {}

    // MARK: - Word replacement

    /// Deletes `backspaceCount` characters in CURRENT layout, THEN switches layout, THEN types `newText`.
    /// This prevents dropped backspaces caused by macOS freezing input queues during layout transitions.
    public func replaceLastWord(
        backspaceCount: Int,
        newText: String,
        targetLanguage: SupportedLanguage
    ) {
        guard backspaceCount > 0, !newText.isEmpty else { return }

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }

            // Set barrier so KeyboardMonitor completely ignores all synthetic backspaces and chars
            KeyboardMonitor.isReplacing = true
            defer {
                // Ensure barrier is released after typing finishes
                usleep(15_000)
                KeyboardMonitor.isReplacing = false
            }

            // 1. Delete the incorrect word FIRST while the application is in its current, stable state
            self.emitBackspaces(count: backspaceCount)

            // 2. Small settling delay after deleting
            usleep(25_000)

            // 3. Switch layout synchronously so the next typed characters are in the new layout
            LayoutManager.shared.switchTo(language: targetLanguage)

            // 4. Wait for macOS WindowServer to finish applying the new input source
            usleep(45_000)

            // 5. Type the clean, converted text
            self.emitString(newText)
        }
    }

    // MARK: - Selected text conversion

    /// Gets selected text via Accessibility, converts it, pastes it back.
    /// Falls back to plain layout toggle if nothing is selected.
    public func convertSelectedTextOrToggle() {
        if let selected = getSelectedText(), !selected.isEmpty {
            convertSelectedText(selected)
        } else {
            _ = LayoutManager.shared.toggleLanguage()
        }
    }

    // MARK: - Private helpers

    private func emitBackspaces(count: Int) {
        let src = eventSource
        for _ in 0..<count {
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false)
            else { continue }
            // Strip modifier flags so app doesn't see Cmd+Backspace or Shift+Backspace!
            down.flags = []
            up.flags   = []
            down.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMarker)
            up.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMarker)
            
            // Post keyDown, hold briefly, then post keyUp
            down.post(tap: .cghidEventTap)
            usleep(4_000)  // 4 ms key hold time
            up.post(tap: .cghidEventTap)
            usleep(8_000)  // 8 ms gap between strokes (total 12ms per backspace)
        }
    }

    private func emitString(_ text: String) {
        guard !text.isEmpty else { return }
        let src = eventSource
        var utf16 = Array(text.utf16)

        // Atomic text insertion: send the entire word in a SINGLE CGEvent!
        // This eliminates letter-by-letter lag and completely prevents macOS predictive engine from inserting phantom '1' or '2' digits.
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        else { return }

        down.flags = []
        up.flags   = []
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMarker)

        down.post(tap: .cghidEventTap)
        usleep(4_000)
        up.post(tap: .cghidEventTap)
    }

    private func getSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()

        var rawApp: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &rawApp) == .success,
              let app = rawApp else { return nil }

        var rawElement: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &rawElement) == .success,
              let element = rawElement else { return nil }

        // Must verify that there is an ACTUAL non-zero selection length!
        // Many apps keep old text in kAXSelectedTextAttribute even when nothing is selected.
        var rawRange: CFTypeRef?
        if AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextRangeAttribute as CFString, &rawRange) == .success,
           let rangeValue = rawRange {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                guard range.length > 0 else { return nil }
            }
        }

        var rawText: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &rawText) == .success,
              let text = rawText as? String, !text.isEmpty else { return nil }

        return text
    }

    private func convertSelectedText(_ selectedText: String) {
        let pasteboard = NSPasteboard.general

        // Snapshot current clipboard
        let snapshot = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data]? in
            var dict = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict.isEmpty ? nil : dict
        }

        // Determine conversion
        let currentLang = LayoutManager.shared.currentLanguage()
        let decision    = ThreeWayEngine.shared.cycleText(selectedText, currentLanguage: currentLang)

        // Switch layout, put converted text on clipboard, paste
        LayoutManager.shared.switchTo(language: decision.targetLanguage)
        pasteboard.clearContents()
        pasteboard.setString(decision.convertedText, forType: .string)
        simulateKey(keyCode: 9, flags: .maskCommand)  // Cmd+V

        // Restore original clipboard after paste completes
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 0.4) {
            guard let saved = snapshot, !saved.isEmpty else { return }
            pasteboard.clearContents()
            for dict in saved {
                let item = NSPasteboardItem()
                for (type, data) in dict { item.setData(data, forType: type) }
                pasteboard.writeObjects([item])
            }
        }
    }

    private func simulateKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let down = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: true),
              let up   = CGEvent(keyboardEventSource: eventSource, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags   = flags
        down.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMarker)
        up.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMarker)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
