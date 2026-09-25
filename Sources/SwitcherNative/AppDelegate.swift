import Foundation
import AppKit
import Carbon

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var currentLanguageItem: NSMenuItem!
    private var autoSwitchItem: NSMenuItem!
    private var wordsSubmenuItem: NSMenuItem!
    private var permissionRetryCount = 0
    private let maxPermissionRetries = 15

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusBar()
        checkPermissionsAndStart()

        // Observe current layout change to update menu title
        let selectedName = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        DistributedNotificationCenter.default().addObserver(
            forName: selectedName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateLanguageDisplay()
            }
        }

        // Re-check permissions when application becomes active (user returns from System Settings)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            if !KeyboardMonitor.shared.isStarted && AXIsProcessTrusted() {
                _ = KeyboardMonitor.shared.start()
            }
        }
    }

    private func setupStatusBar() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        }

        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "globe", accessibilityDescription: "SwitcherNative") {
                image.isTemplate = true
                button.image = image
                button.imagePosition = .imageLeading
            } else {
                button.title = "UA"
            }
        }

        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "SwitcherNative (Apple Silicon M4)", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        currentLanguageItem = NSMenuItem(title: "Поточна мова: ...", action: nil, keyEquivalent: "")
        currentLanguageItem.isEnabled = false
        menu.addItem(currentLanguageItem)

        menu.addItem(NSMenuItem.separator())

        autoSwitchItem = NSMenuItem(
            title: "Автоперемикання «на льоту»",
            action: #selector(toggleAutoSwitch),
            keyEquivalent: ""
        )
        autoSwitchItem.state = SettingsManager.shared.autoSwitchEnabled ? .on : .off
        menu.addItem(autoSwitchItem)

        menu.addItem(NSMenuItem.separator())

        // Hotkey submenu
        let hotkeyMenu = NSMenu()
        for mode in HotkeyMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(selectHotkeyMode(_:)), keyEquivalent: "")
            item.representedObject = mode
            item.state = (SettingsManager.shared.hotkeyMode == mode) ? .on : .off
            hotkeyMenu.addItem(item)
        }
        let hotkeySubmenuItem = NSMenuItem(title: "Гаряча клавіша виправлення", action: nil, keyEquivalent: "")
        hotkeySubmenuItem.submenu = hotkeyMenu
        menu.addItem(hotkeySubmenuItem)

        // Excluded Words submenu
        wordsSubmenuItem = NSMenuItem(title: "Слова-виключення", action: nil, keyEquivalent: "")
        wordsSubmenuItem.submenu = makeExcludedWordsMenu()
        menu.addItem(wordsSubmenuItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(title: "Перевірити дозволи (Accessibility)...", action: #selector(openPermissionsSettings), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Про програму...", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Вийти", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
        updateLanguageDisplay()
    }

    private func makeExcludedWordsMenu() -> NSMenu {
        let menu = NSMenu()
        
        let addItem = NSMenuItem(title: "+ Додати слово-виключення...", action: #selector(promptAddExcludedWord), keyEquivalent: "")
        menu.addItem(addItem)
        menu.addItem(NSMenuItem.separator())

        let list = SettingsManager.shared.excludedWords
        if list.isEmpty {
            let emptyItem = NSMenuItem(title: "(Немає доданих слів)", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            let infoItem = NSMenuItem(title: "Клікніть по слову для видалення:", action: nil, keyEquivalent: "")
            infoItem.isEnabled = false
            menu.addItem(infoItem)

            for word in list {
                let item = NSMenuItem(title: "✕  \(word)", action: #selector(removeExcludedWordAction(_:)), keyEquivalent: "")
                item.representedObject = word
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func promptAddExcludedWord() {
        let alert = NSAlert()
        alert.messageText = "Додати слово-виключення"
        alert.informativeText = "Введіть слово або абревіатуру, яку програма ніколи не перемикатиме:"
        alert.alertStyle = .informational

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.placeholderString = "наприклад: yt, cmd, sql"
        alert.accessoryView = input

        alert.addButton(withTitle: "Додати")
        alert.addButton(withTitle: "Скасувати")

        // Activate app so alert is in focus
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let word = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty {
                SettingsManager.shared.addExcludedWord(word)
                refreshMenu()
            }
        }
    }

    @objc private func removeExcludedWordAction(_ sender: NSMenuItem) {
        guard let word = sender.representedObject as? String else { return }
        let alert = NSAlert()
        alert.messageText = "Видалити слово-виключення"
        alert.informativeText = "Видалити «\(word)» зі списку виключень?"
        alert.addButton(withTitle: "Видалити")
        alert.addButton(withTitle: "Скасувати")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            SettingsManager.shared.removeExcludedWord(word)
            refreshMenu()
        }
    }

    private func refreshMenu() {
        wordsSubmenuItem?.submenu = makeExcludedWordsMenu()
    }

    private func updateLanguageDisplay() {
        let lang = LayoutManager.shared.currentLanguage()
        currentLanguageItem.title = "Поточна мова: \(lang.displayName)"
        if let button = statusItem.button {
            switch lang {
            case .ukrainian:
                button.title = "UA"
            case .english:
                button.title = "EN"
            }
        }
    }

    private func checkPermissionsAndStart() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)

        if trusted {
            let started = KeyboardMonitor.shared.start()
            print("[AppDelegate] Accessibility granted. Monitor started: \(started)")
            if !started {
                // EventTap failed even with permissions - retry once after a delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    let ok = KeyboardMonitor.shared.start()
                    print("[AppDelegate] Monitor retry: \(ok)")
                }
            }
        } else {
            print("[AppDelegate] Accessibility NOT granted. Showing prompt and polling...")
            promptPermissionsAlert()
            permissionRetryCount = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.retryStartUntilGranted()
            }
        }
    }

    private func retryStartUntilGranted() {
        let trusted = AXIsProcessTrusted()
        if trusted {
            let started = KeyboardMonitor.shared.start()
            print("[AppDelegate] Permission granted, monitor started: \(started)")
        } else {
            permissionRetryCount += 1
            if permissionRetryCount < maxPermissionRetries {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.retryStartUntilGranted()
                }
            } else {
                print("[AppDelegate] Stopped polling permissions. Will recheck when app becomes active.")
            }
        }
    }

    private func promptPermissionsAlert() {
        let alert = NSAlert()
        alert.messageText = "Потрібні дозволи доступу (Accessibility)"
        alert.informativeText = "Для автоматичного виправлення розкладки SwitcherNative потребує доступу в розділі «Конфіденційність і безпека > Універсальний доступ».\n\nБудь ласка, дозвольте доступ для SwitcherNative."
        alert.addButton(withTitle: "Відкрити налаштування")
        alert.addButton(withTitle: "Пізніше")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            openPermissionsSettings()
        }
    }

    @objc private func toggleAutoSwitch() {
        let current = SettingsManager.shared.autoSwitchEnabled
        SettingsManager.shared.autoSwitchEnabled = !current
        autoSwitchItem.state = !current ? .on : .off
    }

    @objc private func selectHotkeyMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? HotkeyMode else { return }
        SettingsManager.shared.hotkeyMode = mode
        if let parent = sender.menu {
            for item in parent.items {
                item.state = (item == sender) ? .on : .off
            }
        }
    }

    @objc private func openPermissionsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "SwitcherNative 1.0 (Apple Silicon M4)"
        alert.informativeText = "Нативний перемикач розкладки клавіатури для macOS (Apple Silicon M4).\nРозкладки: Українська та English (із підтримкою вводу через Option).\n\nПрацює нативно без Rosetta, 100% приватно та безкоштовно."
        alert.addButton(withTitle: "Гаразд")
        alert.runModal()
    }

    @objc private func quitApp() {
        KeyboardMonitor.shared.stop()
        NSApplication.shared.terminate(nil)
    }
}
