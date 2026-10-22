import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

@MainActor
final class TypingController: ObservableObject {
    @Published private(set) var state: RunState = .ready
    @Published private(set) var lastPlan: TypingPlan?
    @Published private(set) var progress = PlaybackProgress()
    @Published private(set) var pauseMessage: String?
    @Published private(set) var savedRun: SavedTypingRun?
    @Published private(set) var savedRunError: String?
    @Published private(set) var isSavingForLater = false
    @Published var overlayEnabled = true { didSet { refreshOverlay() } }
    private let screenOverlay = TypingScreenOverlay()
    private var target: NSRunningApplication?
    private var targetField: AXUIElement?
    private var focusObserver: NSObjectProtocol?

    private var countdownTask: Task<Void, Never>?
    private var planningTask: Task<Void, Never>?
    private var playbackSession: PlaybackSession?
    private let savedRuns: SavedRunStore?
    private var runContext: TypingRunContext?
    private var preserveOnQuit = false
    private var saveTask: Task<Bool, Never>?
    private var saveID = UUID()
    private var pausedFieldTask: Task<SavedFieldState?, Never>?
    private let playbackQueue = DispatchQueue(label: "typer.playback", qos: .userInitiated)

    let shortcuts: ShortcutManager
    var onArm: (() -> Void)?

    init(shortcuts: ShortcutManager? = nil, savedRuns: SavedRunStore? = nil) {
        self.savedRuns = savedRuns
        let shortcuts = shortcuts ?? ShortcutManager()
        self.shortcuts = shortcuts
        shortcuts.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .arm: self.onArm?()
            case .pause: self.togglePause()
            case .skipWait: self.skipWait()
            case .stop: self.stop()
            }
        }
        shortcuts.onBindingsChanged = { [weak self] in self?.refreshOverlay() }
        screenOverlay.onPauseResume = { [weak self] in self?.togglePause() }
        screenOverlay.onSkipWait = { [weak self] in self?.skipWait() }
        screenOverlay.onStop = { [weak self] in self?.stop() }
        screenOverlay.onSaveLater = { [weak self] in self?.requestSaveForLater() }
        shortcuts.start()
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.state == .typing,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier != self.target?.processIdentifier else { return }
                    self.pause(message: "App changed. Return to the same field in \(self.target?.localizedName ?? "the target app") to resume.")
                }
            }
        if let savedRuns {
            do {
                savedRun = try savedRuns.load()
                if let savedRun {
                    lastPlan = savedRun.plan
                    runContext = savedRun.context
                    progress = savedRun.progress
                    state = .stopped
                    preserveOnQuit = true
                }
            } catch { savedRunError = error.localizedDescription }
        }
    }

    deinit {
        if let focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(focusObserver) }
        playbackSession?.cancel()
        pausedFieldTask?.cancel()
    }

    var accessibilityGranted: Bool { AXIsProcessTrusted() }

    @discardableResult
    func requestAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func start(text: String, settings: TypingSettings, profile: TypingProfile) {
        guard !text.isEmpty else { return }
        guard accessibilityGranted else {
            _ = requestAccessibility()
            state = .error("Enable Typer in System Settings → Privacy & Security → Accessibility.")
            return
        }
        guard discardSession(resetState: false) else { return }
        runContext = TypingRunContext(text: text, settings: settings)
        state = .preparing
        planningTask = Task { [weak self] in
            let plan = await Task.detached(priority: .userInitiated) {
                TypingEngine.generatePlan(text: text, settings: settings, profile: profile)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.planningTask = nil
            self.startCountdown(with: plan)
        }
    }

    func start(plan: TypingPlan, context: TypingRunContext? = nil) {
        guard !plan.events.isEmpty else { return }
        guard accessibilityGranted else {
            _ = requestAccessibility()
            state = .error("Enable Typer in System Settings → Privacy & Security → Accessibility.")
            return
        }
        guard discardSession(resetState: false) else { return }
        runContext = context
        startCountdown(with: plan)
    }

    private func startCountdown(with plan: TypingPlan, saved: SavedTypingRun? = nil) {
        if let error = shortcuts.preparePlayback() { state = .error(error); return }
        lastPlan = plan
        state = .armed(5)
        countdownTask = Task { [weak self] in
            for count in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                if count > 0 { self.state = .armed(count) }
            }
            guard !Task.isCancelled, let self else { return }
            guard !NSApp.isActive else {
                self.rejectStart("Click into the original document before the countdown ends.")
                return
            }
            self.begin(plan, saved: saved)
        }
    }

    func stop(resetState: Bool = true) {
        // Retain the exact scheduler position, including any unfinished repair.
        // Pausing releases held keys and cancels an unfinished accent safely.
        if resetState, playbackSession != nil || savedRun != nil, state.isPlaybackActive || isResuming {
            let wasTyping = state == .typing
            countdownTask?.cancel(); countdownTask = nil
            playbackSession?.pause()
            shortcuts.finishPlayback()
            screenOverlay.hide()
            pauseMessage = nil
            progress.isPaused = true
            state = .stopped
            if wasTyping { capturePausedField() }
            return
        }
        // Repeated Stop must not accidentally erase the saved position.
        if resetState, state == .stopped, canResume { return }
        discardSession(resetState: resetState)
    }

    @discardableResult
    func discardSession(resetState: Bool = true, removeSavedRun: Bool = true) -> Bool {
        if removeSavedRun {
            do { try savedRuns?.remove() }
            catch { savedRunError = "Could not remove the saved run: \(error.localizedDescription)"; return false }
            savedRun = nil
            savedRunError = nil
            preserveOnQuit = false
        }
        saveID = UUID(); saveTask?.cancel(); saveTask = nil; isSavingForLater = false
        pausedFieldTask?.cancel(); pausedFieldTask = nil
        planningTask?.cancel()
        planningTask = nil
        countdownTask?.cancel()
        countdownTask = nil
        playbackSession?.cancel()
        playbackSession = nil
        shortcuts.finishPlayback()
        screenOverlay.hide()
        target = nil
        targetField = nil
        pauseMessage = nil
        runContext = savedRun?.context
        progress = savedRun?.progress ?? PlaybackProgress()
        if resetState { state = .stopped }
        return true
    }

    var canResume: Bool { (playbackSession != nil || savedRun != nil) && (state == .paused || state == .stopped) }
    var canSaveForLater: Bool { savedRuns != nil && runContext != nil && playbackSession != nil && !isSavingForLater }
    var needsSavedRunRecovery: Bool { savedRun == nil && playbackSession == nil && savedRunError != nil && savedRuns?.hasStoredRun == true }
    private var isResuming: Bool { if case .armed = state { return playbackSession != nil || savedRun != nil }; return false }

    func reset() { if !state.isBusy && !canResume { state = .ready } }

    /// A stopped run uses the ordinary countdown so the user can restore the
    /// original field before anything is sent. Nothing is regenerated.
    func resumeStopped() {
        guard state == .stopped, canResume else { return }
        guard !isSavingForLater else { return }
        if playbackSession == nil, let savedRun {
            startCountdown(with: savedRun.plan, saved: savedRun)
            return
        }
        guard let target, !target.isTerminated else {
            pauseMessage = "The target app closed. Start a new run in a new field."
            return
        }
        if let error = shortcuts.preparePlayback() { pauseMessage = error; return }
        state = .armed(5)
        countdownTask = Task { [weak self] in
            for count in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if count > 0 { self.state = .armed(count) }
            }
            guard !Task.isCancelled, let self else { return }
            self.countdownTask = nil
            self.state = .paused
            self.togglePause()
        }
    }

    /// Only an explicit save stores source text. Once a saved run is resumed,
    /// a normal Quit saves its new position too. A failed write keeps it paused.
    func requestSaveForLater() { _ = beginSavingForLater() }

    @discardableResult
    func saveForLater() async -> Bool {
        guard let task = beginSavingForLater() else { return savedRun != nil }
        return await task.value
    }

    private func beginSavingForLater() -> Task<Bool, Never>? {
        if let saveTask { return saveTask }
        guard playbackSession != nil else { return nil }
        if state == .typing { pause() }
        let id = UUID(); saveID = id
        // Mark the request before returning to the UI, so an immediate Quit
        // waits for this same write instead of discarding the live session.
        isSavingForLater = true
        preserveOnQuit = true
        savedRunError = nil
        pauseMessage = "Saving this run…"
        refreshOverlay()
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            var success = false
            defer {
                if self.saveID == id {
                    self.saveTask = nil; self.isSavingForLater = false
                    if !success, self.pauseMessage == "Saving this run…" { self.pauseMessage = nil }
                    self.refreshOverlay()
                }
            }
            guard self.playbackSession != nil else { return self.savedRun != nil }
            guard let store = self.savedRuns, let plan = self.lastPlan, let context = self.runContext,
                  let session = self.playbackSession, let target = self.target,
                  let checkpoint = session.checkpoint() else {
                self.savedRunError = "This run could not be saved. It is still paused in Typer."
                return false
            }
            // Use the cursor captured when we paused, even if the user later
            // clicked elsewhere before choosing Save and resume later.
            let field = await self.pausedFieldTask?.value
            guard !Task.isCancelled, self.playbackSession === session, self.saveID == id else { return false }
            let actions = KeyTimeline.physicalActions(for: plan.events, layout: session.layout)
            var savedPlan = plan
            savedPlan.duration = actions.last?.scheduledOffset ?? plan.duration
            var savedCheckpoint = checkpoint
            savedCheckpoint.elapsed = min(checkpoint.elapsed, savedPlan.duration / 1_000)
            let run = SavedTypingRun(context: context, plan: savedPlan, checkpoint: savedCheckpoint,
                layoutIdentifier: session.layout.identifier, actions: actions,
                targetBundleIdentifier: target.bundleIdentifier, targetName: target.localizedName ?? "the target app", field: field)
            do { try store.save(run) }
            catch { self.savedRunError = "Could not save this run: \(error.localizedDescription)"; return false }
            session.cancel(); self.playbackSession = nil
            self.countdownTask?.cancel(); self.countdownTask = nil
            self.shortcuts.finishPlayback(); self.screenOverlay.hide()
            self.target = nil; self.targetField = nil
            self.pausedFieldTask = nil
            self.savedRun = run; self.savedRunError = nil; self.preserveOnQuit = true
            self.progress = run.progress
            self.pauseMessage = nil; self.state = .stopped
            success = true
            return true
        }
        saveTask = task
        return task
    }

    func prepareForQuit() async -> Bool {
        if saveTask != nil || isSavingForLater || (preserveOnQuit && playbackSession != nil) { return await saveForLater() }
        return discardSession(removeSavedRun: false)
    }

    func togglePause() {
        guard !isSavingForLater else { return }
        if state == .typing { pause() }
        else if state == .stopped { resumeStopped() }
        else if state == .paused {
            guard let target, !target.isTerminated,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier else {
                pauseMessage = "Focus the same field in \(target?.localizedName ?? "the target app") before resuming."
                refreshOverlay()
                return
            }
            if let targetField, !KeyboardEventPoster.canCleanUpComposition(in: target.processIdentifier, field: targetField) {
                pauseMessage = "Click the original text field in \(target.localizedName ?? "the target app"), then resume."
                refreshOverlay()
                return
            }
            playbackSession?.resume()
            pausedFieldTask?.cancel(); pausedFieldTask = nil
            pauseMessage = nil
            progress.isPaused = false
            state = .typing
            refreshOverlay()
        }
    }

    func pause(message: String? = nil) {
        guard state == .typing else { return }
        playbackSession?.pause()
        state = .paused
        pauseMessage = message
        progress.isPaused = true
        capturePausedField()
        refreshOverlay()
    }

    private func capturePausedField() {
        pausedFieldTask?.cancel()
        guard let session = playbackSession else { pausedFieldTask = nil; return }
        let field = targetField
        pausedFieldTask = Task { @MainActor [weak self] in
            // Key-up and Escape cleanup are asynchronous in the destination.
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return nil }
            guard !Task.isCancelled, let self, self.playbackSession === session,
                  self.state != .typing, session.checkpoint()?.rewindOwner == nil else { return nil }
            return field.flatMap { KeyboardEventPoster.captureFieldState($0) }
        }
    }

    func skipWait() {
        guard state == .typing else { return }
        _ = playbackSession?.skipWait()
    }

    func focusTarget() { target?.activate(options: []) }

    private func refreshOverlay() {
        screenOverlay.update(state: state, progress: progress, target: target?.localizedName ?? "the target app",
                             message: savedRunError ?? pauseMessage, enabled: overlayEnabled, shortcuts: shortcuts.bindings,
                             stopText: shortcuts.stopDescription, canSaveLater: canSaveForLater, saving: isSavingForLater)
    }

    private func rejectStart(_ message: String) {
        shortcuts.finishPlayback()
        if savedRun != nil { pauseMessage = message; state = .stopped }
        else { state = .error(message) }
    }

    private func begin(_ plan: TypingPlan, saved: SavedTypingRun? = nil) {
        guard let target = NSWorkspace.shared.frontmostApplication, target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            rejectStart("Focus the target application before typing starts.")
            return
        }
        guard let layout = KeyboardLayout.current() else {
            rejectStart("Choose a keyboard layout such as U.S., British or French before typing. This input method does not expose a direct key layout.")
            return
        }
        let layoutGuard = PlaybackLayoutGuard(identifier: layout.identifier)
        let originalField = KeyboardEventPoster.focusedElement(in: target.processIdentifier)
        if let saved {
            guard saved.targetBundleIdentifier == nil || target.bundleIdentifier == saved.targetBundleIdentifier else {
                rejectStart("Return to the original document in \(saved.targetName), then resume again."); return
            }
            guard saved.isCompatible(with: layout) else {
                rejectStart("Switch back to the saved keyboard layout before resuming. If its mapping has changed, start a new run."); return
            }
            if let field = saved.resumeField {
                guard let originalField, KeyboardEventPoster.restoreFieldState(field, in: originalField) else {
                    rejectStart("This field does not match the saved document, or its cursor could not be restored. Open the original unchanged text field, then resume again."); return
                }
            }
            // Consume the old checkpoint before sending any new text. A crash
            // must not offer a stale cursor that would repeat already sent keys.
            do { try savedRuns?.remove() }
            catch { rejectStart("Could not open the saved run: \(error.localizedDescription)"); return }
            savedRun = nil
            runContext = saved.context
            preserveOnQuit = true
        }
        let source = CGEventSource(stateID: .privateState)
        let session = PlaybackSession(layout: layout) { action in
            if action.isDown && !layoutGuard.isCurrent { return false }
            if action.isCompositionCleanup && !KeyboardEventPoster.canCleanUpComposition(in: target.processIdentifier, field: originalField) { return false }
            guard let event = KeyboardEventPoster.make(action, source: source) else { return false }
            // Bind this run, including cleanup releases, to its chosen app.
            // The global HID route can have modifier combinations intercepted
            // before they reach the target (observed in Safari symbol checks).
            KeyboardEventPoster.post(event, to: target.processIdentifier)
            return true
        }
        run(plan: plan, session: session, target: target, field: originalField, checkpoint: saved?.resumeCheckpoint)
    }

    /// Starts an already prepared transport. Kept separate from event creation
    /// so lifecycle checks can run without sending keys to another application.
    func run(plan: TypingPlan, session: PlaybackSession, target: NSRunningApplication, field: AXUIElement?,
             context: TypingRunContext? = nil, checkpoint: PlaybackCheckpoint? = nil) {
        if let checkpoint { session.prepare(checkpoint: checkpoint) }
        if let context { runContext = context }
        self.target = target
        self.targetField = field
        lastPlan = plan
        state = .typing
        let actionCount = checkpoint.map { _ in KeyTimeline.physicalActions(for: plan.events, layout: session.layout).count } ?? 0
        progress = PlaybackProgress(fraction: checkpoint.map { Double($0.nextAction) / Double(max(1, actionCount)) } ?? 0,
                                    remaining: max(0, plan.duration / 1_000 - (checkpoint?.elapsed ?? 0)))
        playbackSession = session
        refreshOverlay()
        playbackQueue.async { [weak self] in
            let outcome = session.run(plan: plan, checkpoint: checkpoint, onProgress: { progress in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playbackSession === session, self.state.isPlaybackActive else { return }
                    var progress = progress
                    progress.isPaused = self.state != .typing
                    if self.progress != progress {
                        self.progress = progress
                        self.refreshOverlay()
                    }
                }
            })
            DispatchQueue.main.async { [weak self] in
                guard let self, self.playbackSession === session else { return }
                self.playbackSession = nil
                self.shortcuts.finishPlayback()
                self.screenOverlay.hide()
                self.target = nil
                self.targetField = nil
                self.preserveOnQuit = false
                switch outcome {
                case .complete: self.state = .complete
                case .cancelled: self.state = .stopped
                case .failed: self.state = .error("Typing stopped because the keyboard layout changed or a key could not be sent. Check the field for an unfinished accent before starting again.")
                }
            }
        }
    }

}

/// The diagnostic receiver and cross-app playback share the same event creation.
/// Only the destination differs: the diagnostic posts to Typer's process alone.
enum KeyboardEventPoster {
    static func captureFieldState(_ field: AXUIElement) -> SavedFieldState? {
        AXUIElementSetMessagingTimeout(field, 0.2)
        var textValue: CFTypeRef?, rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &textValue) == .success,
              let text = textValue as? String,
              AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        let axRange = unsafeBitCast(rangeValue, to: AXValue.self)
        guard AXValueGetValue(axRange, .cfRange, &range), range.location >= 0, range.length >= 0,
              range.location <= text.utf16.count, range.length <= text.utf16.count - range.location else { return nil }
        return SavedFieldState(documentDigest: SavedFieldState.digest(text), selection: NSRange(location: range.location, length: range.length))
    }

    static func restoreFieldState(_ saved: SavedFieldState, in field: AXUIElement) -> Bool {
        guard let current = captureFieldState(field), current.documentDigest == saved.documentDigest else { return false }
        if current.selection == saved.selection { return true }
        var range = CFRange(location: saved.selection.location, length: saved.selection.length)
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, value) == .success else { return false }
        return captureFieldState(field) == saved
    }

    static func focusedElement(in processID: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    static func canCleanUpComposition(in processID: pid_t, field: AXUIElement?) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let field, let current = focusedElement(in: processID) else { return false }
        return CFEqual(field, current)
    }

    static func post(_ event: CGEvent, to processID: pid_t) {
        event.postToPid(processID)
    }

    static func make(_ action: PhysicalKeyAction, source: CGEventSource?, marker: Int64 = 0) -> CGEvent? {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: action.code, keyDown: action.isDown) else { return nil }
        event.flags = []
        if action.shift { event.flags.insert(.maskShift) }
        if action.option { event.flags.insert(.maskAlternate) }
        if !action.unicode.isEmpty {
            let units = Array(action.unicode.utf16)
            units.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
            }
        }
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        return event
    }
}
