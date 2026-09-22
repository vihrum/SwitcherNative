import Foundation
import AppKit
import Carbon

// Unique marker so our own CGEventTap ignores synthetic events
let kSyntheticEventMarker: Int64 = 0x5357_4954_4348  // "SWITCH"

public final class TextReplacer {
    public static let shared = TextReplacer()

    // Private event source — combinedSessionState is cheaper than hidSystemState
    // for generating synthetic events
    private let eventSource = CGEventSource(stateID: .combinedSessionState)

    private init() {}

    // MARK: - Word replacement

    /// Deletes `backspaceCount` characters then types `newText`.
    /// All events are tagged so our CGEventTap skips them.
    public func replaceLastWord(
        backspaceCount: Int,
        newText: String,
        targetLanguage: SupportedLanguage
    ) {
        guard backspaceCount > 0, !newText.isEmpty else { return }

        // Switch layout synchronously before emitting events
        LayoutManager.shared.switchTo(language: targetLanguage)

        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            // Small pause to let any physically held Command key release in the OS event queue
            usleep(25_000)
            self.emitBackspaces(count: backspaceCount)
            usleep(20_000)  // gap so target app finishes deleting
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
            // Critical: strip ALL modifier flags so app doesn't see Cmd+Backspace or Shift+Backspace!
            down.flags = []
            up.flags   = []
            down.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMarker)
            up.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMarker)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(5_000)  // 5 ms between backspaces
        }
    }

    private func emitString(_ text: String) {
        let src = eventSource
        for scalar in text.unicodeScalars {
            var c = scalar.utf16.first ?? 0
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up   = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else { continue }
            down.flags = []
            up.flags   = []
            down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &c)
            down.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMarker)
            up.setIntegerValueField(.eventSourceUserData, value: kSyntheticEventMarker)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(2_500)
        }
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
