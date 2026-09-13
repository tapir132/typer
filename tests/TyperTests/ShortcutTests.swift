import AppKit
import Carbon.HIToolbox
import SwiftUI
import Testing
@testable import Typer

@MainActor
final class TestShortcutDriver: ShortcutRegistering {
    var onPress: ((UInt32) -> Void)?
    var bindings: [UInt32: ShortcutBinding] = [:]
    var unavailable: [ShortcutBinding] = []
    func register(_ binding: ShortcutBinding, id: UInt32) -> Bool {
        guard !unavailable.contains(where: { $0.matches(binding) }),
              !bindings.contains(where: { $0.key != id && $0.value.matches(binding) }) else { return false }
        bindings[id] = binding
        return true
    }
    func unregister(_ id: UInt32) { bindings[id] = nil }
}

@MainActor
@Suite(.serialized)
struct ShortcutTests {
    private func withManager(_ body: (ShortcutManager, TestShortcutDriver, UserDefaults) throws -> Void) throws {
        _ = NSApplication.shared
        let suite = "typer.shortcuts-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let driver = TestShortcutDriver()
        let manager = ShortcutManager(defaults: defaults, driver: driver)
        manager.start(); manager.setAppActive(true)
        try body(manager, driver, defaults)
    }

    @Test func savedBindingsReplaceOldKeysAndRestoreDefaults() throws {
        try withManager { manager, driver, defaults in
            let binding = ShortcutBinding(keyCode: 96, modifiersRawValue: 0, keyLabel: "F5")
            #expect(manager.beginRecording(.stop))
            #expect(driver.bindings.isEmpty)
            #expect(manager.setBinding(binding, for: .stop) == nil)
            manager.endRecording(.stop)
            #expect(driver.bindings[ShortcutAction.stop.rawValue] == binding)
            #expect(!driver.bindings.values.contains(where: { $0.matches(ShortcutBindings().stop) }))
            let reloaded = ShortcutManager(defaults: defaults, driver: TestShortcutDriver())
            #expect(reloaded.bindings.stop == binding)
            manager.restoreDefaults()
            #expect(manager.bindings == ShortcutBindings())
            #expect(ShortcutManager(defaults: defaults, driver: TestShortcutDriver()).bindings == ShortcutBindings())
        }
    }

    @Test func duplicateReservedAndOSConflictsKeepTheOldBinding() throws {
        try withManager { manager, driver, defaults in
            #expect(manager.beginRecording(.pause))
            #expect(manager.setBinding(manager.bindings.stop, for: .pause) != nil)
            #expect(manager.setBinding(ShortcutBindings.backupStop, for: .pause) != nil)
            let blocked = ShortcutBinding(keyCode: 96, modifiersRawValue: 0, keyLabel: "F5")
            driver.unavailable = [blocked]
            #expect(manager.setBinding(blocked, for: .pause) != nil)
            #expect(manager.bindings == ShortcutBindings())
            #expect(defaults.data(forKey: "typer.shortcuts.v1") == nil)
            manager.endRecording(.pause)
            #expect(driver.bindings[ShortcutAction.stop.rawValue] != nil)
        }
    }

    @Test func playbackRequiresPauseSkipAndAtLeastOneWorkingStop() throws {
        try withManager { manager, driver, _ in
            driver.unavailable = [manager.bindings.stop, ShortcutBindings.backupStop]
            #expect(manager.beginRecording(.arm))
            manager.endRecording(.arm)
            #expect(manager.preparePlayback() != nil)
            #expect(!manager.playbackActive)
            driver.unavailable = [manager.bindings.stop]
            #expect(manager.preparePlayback() == nil)
            #expect(manager.stopDescription == ShortcutBindings.backupStop.displayText)
            #expect(!manager.beginRecording(.stop))
            manager.finishPlayback()
            driver.unavailable = [manager.bindings.pause]
            #expect(manager.preparePlayback() != nil)
        }
    }

    @Test func actionsRespectAppFocusPlaybackRecordingAndPreview() throws {
        try withManager { manager, driver, _ in
            var received: [ShortcutAction] = []
            manager.onAction = { received.append($0) }
            driver.onPress?(ShortcutAction.arm.rawValue)
            #expect(received == [.arm])
            manager.setAppActive(false)
            driver.onPress?(ShortcutAction.arm.rawValue)
            #expect(received == [.arm])
            #expect(manager.preparePlayback() == nil)
            driver.onPress?(ShortcutAction.pause.rawValue)
            driver.onPress?(ShortcutAction.skipWait.rawValue)
            driver.onPress?(5)
            #expect(received == [.arm, .pause, .skipWait, .stop])
            manager.finishPlayback(); manager.setAppActive(true)
            var preview: [ShortcutAction] = []
            manager.beginPreview { preview.append($0) }
            #expect(manager.preparePlayback() != nil)
            driver.onPress?(ShortcutAction.pause.rawValue)
            #expect(preview == [.pause] && received.count == 4)
            manager.perform(.stop)
            #expect(preview == [.pause, .stop] && received.count == 4)
            manager.endPreview()
            #expect(manager.beginRecording(.arm))
            driver.onPress?(ShortcutAction.stop.rawValue)
            #expect(received.count == 4)
            manager.endRecording(.arm)
        }
    }

    @Test func modifiersIgnoreKeyboardStateAndRejectPlainTyping() throws {
        let event = try key(.keyDown, code: 2, flags: [.command, .shift, .capsLock, .numericPad], characters: "D")
        let binding = try #require(ShortcutBinding.from(event))
        #expect(binding.modifiers == [.command, .shift])
        #expect(binding.carbonModifiers == UInt32(cmdKey | shiftKey))
        #expect(binding.displayText == "⇧⌘D")
        #expect(ShortcutBinding.from(try key(.keyDown, code: 2, flags: .shift, characters: "D")) == nil)
        let function = try #require(ShortcutBinding.from(try key(.keyDown, code: 96, flags: .function, characters: "\u{F708}")))
        #expect(function.displayText == "F5" && function.isValid)
        var gesture = ModifierShortcutGesture()
        #expect(gesture.flagsChanged([.control]) == nil)
        #expect(gesture.flagsChanged([.control, .option, .capsLock]) == nil)
        #expect(gesture.flagsChanged([.option]) == nil)
        #expect(gesture.flagsChanged([]) == [.control, .option])
        _ = gesture.flagsChanged([.control, .option]); gesture.cancelChord()
        #expect(gesture.flagsChanged([]) == nil)
        #expect(ShortcutBinding.modifierOnly(.shift) == nil)
    }

    @Test func carbonAutoRepeatOnlyFiresOncePerPress() {
        let driver = SystemShortcutDriver()
        var count = 0
        driver.onPress = { _ in count += 1 }
        for _ in 0..<5 { driver.receiveCarbon(id: 1, isPress: true) }
        #expect(count == 1)
        driver.receiveCarbon(id: 1, isPress: false)
        driver.receiveCarbon(id: 1, isPress: true)
        #expect(count == 2)
    }

    @Test func invalidStoredBindingsFallBackWithoutOverwritingData() throws {
        try withManager { _, _, defaults in
            let corrupt = Data("not JSON".utf8)
            defaults.set(corrupt, forKey: "typer.shortcuts.v1")
            let reloaded = ShortcutManager(defaults: defaults, driver: TestShortcutDriver())
            #expect(reloaded.bindings == ShortcutBindings() && reloaded.loadNotice != nil)
            #expect(defaults.data(forKey: "typer.shortcuts.v1") == corrupt)
        }
    }

    @Test func nativeRecorderCapturesMenuKeysAndWaitsForRelease() throws {
        try withManager { manager, driver, _ in
            let (window, recorder) = host(manager, action: .pause)
            defer { window.close() }
            recorder.beginRecording()
            #expect(driver.bindings.isEmpty)
            NSApp.sendEvent(try key(.keyDown, code: 2, flags: [.command, .shift, .capsLock], characters: "D", window: window))
            #expect(recorder.isRecording && manager.bindings.pause == ShortcutBindings().pause)
            NSApp.sendEvent(try key(.keyUp, code: 2, flags: [.command, .shift], characters: "D", window: window))
            #expect(recorder.isRecording)
            NSApp.sendEvent(try key(.flagsChanged, code: 55, flags: [], characters: "", window: window))
            #expect(!recorder.isRecording && manager.recordingAction == nil)
            #expect(manager.bindings.pause.displayText == "⇧⌘D")
            #expect(manager.preparePlayback() == nil)
            #expect(driver.bindings[ShortcutAction.pause.rawValue]?.displayText == "⇧⌘D")
        }
    }

    @Test func nativeRecorderSupportsFKeysModifiedEscapeAndModifierChords() throws {
        try withManager { manager, _, _ in
            let (window, recorder) = host(manager, action: .stop)
            defer { window.close() }
            recorder.beginRecording()
            NSApp.sendEvent(try key(.keyDown, code: 96, flags: .function, characters: "\u{F708}", window: window))
            NSApp.sendEvent(try key(.keyUp, code: 96, flags: .function, characters: "\u{F708}", window: window))
            #expect(manager.bindings.stop.displayText == "F5")
            recorder.beginRecording()
            NSApp.sendEvent(try key(.keyDown, code: 53, flags: .command, characters: "\u{1B}", window: window))
            NSApp.sendEvent(try key(.keyUp, code: 53, flags: [], characters: "\u{1B}", window: window))
            #expect(manager.bindings.stop.displayText == "⌘Esc")
            recorder.beginRecording()
            for flags: NSEvent.ModifierFlags in [[.control], [.control, .option], [.option], []] {
                NSApp.sendEvent(try key(.flagsChanged, code: 59, flags: flags, characters: "", window: window))
            }
            #expect(manager.bindings.stop.isModifierOnly && manager.bindings.stop.displayText == "⌃⌥")
        }
    }

    @Test func nativeRecorderCleansUpOnEscapeRemovalAndLostFocus() throws {
        try withManager { manager, driver, _ in
            let (window, recorder) = host(manager, action: .pause)
            defer { window.close() }
            recorder.beginRecording()
            NSApp.sendEvent(try key(.keyDown, code: 2, flags: [], characters: "d", window: window))
            #expect(recorder.isRecording && manager.bindings.pause == ShortcutBindings().pause)
            NSApp.sendEvent(try key(.keyDown, code: 53, flags: [], characters: "\u{1B}", window: window))
            #expect(!recorder.isRecording && !driver.bindings.isEmpty)
            recorder.beginRecording()
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            #expect(manager.recordingAction == nil && !recorder.isRecording)
            recorder.beginRecording()
            recorder.removeFromSuperview()
            #expect(manager.recordingAction == nil && !recorder.isRecording && !driver.bindings.isEmpty)
        }
    }

    @Test func settingsRecorderUpdatesVisibleBindingAndCleansUpWhenTabChanges() async throws {
        _ = NSApplication.shared
        let suite = "typer.shortcuts-settings.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ShortcutManager(defaults: defaults, driver: TestShortcutDriver())
        let model = AppModel(profileStore: ProfileStore(defaults: defaults), shortcuts: manager)
        model.settingsSection = .shortcuts
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 800, height: SettingsView.height),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SettingsView(model: model).preferredColorScheme(.dark))
        host.sizingOptions = []
        window.contentView = host
        window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(120))
        let recorder = try #require(findRecorder(in: host, action: .pause))
        let button = try #require(recorder.subviews.compactMap { $0 as? NSButton }.first)
        button.performClick(nil)
        NSApp.sendEvent(try key(.keyDown, code: 96, flags: .function, characters: "\u{F708}", window: window))
        NSApp.sendEvent(try key(.keyUp, code: 96, flags: .function, characters: "\u{F708}", window: window))
        try await Task.sleep(for: .milliseconds(100))
        #expect(button.title == "F5" && manager.bindings.pause.displayText == "F5")
        if let path = ProcessInfo.processInfo.environment["TYPER_LAYOUT_SNAPSHOTS"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("Settings-Shortcuts.png"))
        }
        button.performClick(nil)
        #expect(manager.recordingAction == .pause)
        model.settingsSection = .general
        try await Task.sleep(for: .milliseconds(120))
        #expect(manager.recordingAction == nil && manager.backupAvailable)
    }

    private func findRecorder(in view: NSView, action: ShortcutAction) -> ShortcutRecorderNSView? {
        if let recorder = view as? ShortcutRecorderNSView, recorder.action == action { return recorder }
        return view.subviews.lazy.compactMap { findRecorder(in: $0, action: action) }.first
    }

    private func host(_ manager: ShortcutManager, action: ShortcutAction) -> (NSWindow, ShortcutRecorderNSView) {
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 400, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let recorder = ShortcutRecorderNSView(frame: NSRect(x: 20, y: 40, width: 190, height: 32))
        recorder.shortcuts = manager; recorder.action = action; recorder.updateTitle()
        window.contentView?.addSubview(recorder)
        window.orderBack(nil)
        return (window, recorder)
    }

    private func key(_ type: NSEvent.EventType, code: UInt16, flags: NSEvent.ModifierFlags,
                     characters: String, window: NSWindow? = nil) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window?.windowNumber ?? 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}
