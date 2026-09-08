import AppKit
import Carbon.HIToolbox
import SwiftUI

/// All diagnostic events are swallowed at the application boundary, including
/// late events from a closed/cancelled run. They can only reach the owned editor.
@MainActor
final class PlaybackCheckRouter {
    static let shared = PlaybackCheckRouter()
    nonisolated static let signature: Int64 = 0x5459_0000_0000_0000
    private var route: ((NSEvent, Int64) -> Void)?
    private var userInput: ((NSEvent) -> Bool)?
    private weak var owner: AnyObject?
    private var monitor: Any?

    func acquire(owner: AnyObject, route: @escaping (NSEvent, Int64) -> Void,
                 userInput: @escaping (NSEvent) -> Bool) -> Bool {
        guard self.owner == nil || self.owner === owner else { return false }
        self.owner = owner
        self.route = route
        self.userInput = userInput
        return true
    }

    func release(owner: AnyObject) {
        guard self.owner === owner else { return }
        self.owner = nil
        route = nil
        userInput = nil
    }

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            let marker = event.cgEvent?.getIntegerValueField(.eventSourceUserData) ?? 0
            if marker >> 48 == 0x5459 {
                self?.route?(event, marker)
                return nil
            }
            return self?.userInput?(event) == true ? nil : event
        }
    }
}

private final class PlaybackCheckTransport: @unchecked Sendable {
    let marker = PlaybackCheckRouter.signature | (Int64(UInt32.random(in: 1...UInt32.max)) << 16)
    private let lock = NSLock()
    private var active = true
    private var origin: Double?
    private let source = CGEventSource(stateID: .privateState)

    func began(_ time: Double) { lock.lock(); origin = time; lock.unlock() }
    func disable() { lock.lock(); active = false; lock.unlock() }
    func startedAt() -> Double? { lock.lock(); defer { lock.unlock() }; return origin }

    func post(_ action: PhysicalKeyAction) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard active || !action.isDown else { return false }
        let identity = action.eventIndex.map { $0 * 2 + (action.isDown ? 0 : 1) + 1 } ?? 0
        guard identity < 65_536,
              let event = KeyboardEventPoster.make(action, source: source, marker: marker | Int64(identity)) else { return false }
        // A diagnostic never posts to the global event tap or another process.
        event.postToPid(ProcessInfo.processInfo.processIdentifier)
        return true
    }
}

@MainActor
final class PlaybackCheckController: ObservableObject {
    @Published var scenario: PlaybackCheckScenario = .rhythm
    @Published private(set) var isRunning = false
    @Published private(set) var status = "Choose a check, then keep this window focused while it runs."
    @Published private(set) var report: PlaybackCheckReport?
    weak var receiver: NSTextView?
    private var transport: PlaybackCheckTransport?
    private var session: PlaybackSession?
    private var receipts: [PlaybackReceipt] = []
    private var runScenario: PlaybackCheckScenario = .rhythm
    private var drainTask: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?
    private var inputSource = "Unknown"
    private let requiresFocus: Bool
    private let queue = DispatchQueue(label: "typer.playback-check", qos: .userInitiated)

    // The standalone QA application owns its only editor and can receive its
    // process-addressed events in the background. Normal app UI requires focus.
    init(requiresFocus: Bool = true) { self.requiresFocus = requiresFocus }

    func start() {
        guard AXIsProcessTrusted() else {
            status = "Enable Typer in System Settings → Privacy & Security → Accessibility, then run the check again."
            return
        }
        guard !isRunning, let receiver, let window = receiver.window,
              !requiresFocus || window.isKeyWindow else {
            status = "Click Run check in the active test window to begin."
            return
        }
        let focused = window.makeFirstResponder(receiver)
        guard focused || !requiresFocus else { status = "Click the test editor, then run the check again."; return }
        guard PlaybackCheckRouter.shared.acquire(owner: self, route: { [weak self] event, marker in
            self?.receive(event, marker: marker)
        }, userInput: { [weak self] event in
            guard let self, self.isRunning, event.type == .keyDown, self.receiver?.window?.isKeyWindow == true else { return false }
            self.stop(reason: event.keyCode == 53 ? "Check stopped." : "Check stopped because a physical key was pressed. Run it again without typing.")
            return true
        }) else {
            status = "A playback check is already running in another Typer window. Stop it there before starting this check."
            return
        }
        receiver.string = ""
        receiver.setSelectedRange(NSRange(location: 0, length: 0))
        report = nil
        receipts = []
        runScenario = scenario
        inputSource = Self.currentInputSource()
        let transport = PlaybackCheckTransport()
        self.transport = transport
        let session = PlaybackSession { transport.post($0) }
        self.session = session
        isRunning = true
        status = "Running \(scenario.rawValue.lowercased())… Press Escape or Stop check to stop."
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.requiresFocus == true {
                    self?.stop(reason: "Check stopped because Typer lost focus. Keep the test window active and try again.")
                }
            }
        }
        let plan = scenario.fixture.plan
        queue.async { [weak self] in
            let outcome = session.run(plan: plan, onStart: { transport.began($0) })
            DispatchQueue.main.async {
                guard let self, self.session === session, self.isRunning else { return }
                self.status = "Waiting for the last events…"
                self.drainTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(750))
                    guard !Task.isCancelled, let self, self.session === session else { return }
                    self.finish(completed: outcome == .complete,
                                interruption: outcome == .complete ? nil : "Playback ended before every planned event was sent.")
                }
            }
        }
    }

    func stop(reason: String = "Check stopped.") {
        guard isRunning else { return }
        transport?.disable()
        session?.cancel()
        finish(completed: false, interruption: reason)
    }

    func close() {
        stop()
        PlaybackCheckRouter.shared.release(owner: self)
    }

    private func receive(_ event: NSEvent, marker: Int64) {
        guard isRunning, let transport, marker & ~Int64(65_535) == transport.marker else { return }
        guard let receiver, let window = receiver.window,
              !requiresFocus || (window.isKeyWindow && window.firstResponder === receiver) else {
            stop(reason: "Check stopped because the test editor lost focus.")
            return
        }
        let identifier = Int(marker & 65_535) - 1
        guard identifier >= 0, event.type == .keyDown || event.type == .keyUp, let origin = transport.startedAt() else { return }
        guard receipts.count < runScenario.fixture.plan.events.count * 4 + 32 else {
            stop(reason: "Unexpected extra events were received. Run the check again.")
            return
        }
        receipts.append(PlaybackReceipt(eventIndex: identifier / 2, isDown: event.type == .keyDown, code: event.keyCode,
                                        shift: event.modifierFlags.contains(.shift), option: event.modifierFlags.contains(.option),
                                        eventOffset: (event.timestamp - origin) * 1_000,
                                        receiptOffset: (ProcessInfo.processInfo.systemUptime - origin) * 1_000))
        // Normal NSTextView interpretation exercises real deletion, selection,
        // Unicode input and text handling. The event is consumed by the router.
        receiver.isEditable = true
        defer { receiver.isEditable = false }
        if event.type == .keyDown { receiver.keyDown(with: event) }
        else { receiver.keyUp(with: event) }
    }

    private func finish(completed: Bool, interruption: String?) {
        drainTask?.cancel(); drainTask = nil
        transport?.disable()
        var result = PlaybackCheckReport.analyze(scenario: runScenario, receipts: receipts, text: receiver?.string ?? "",
                                                completed: completed, interruption: interruption, inputSource: inputSource)
        if !requiresFocus {
            result.limitations.append("This automated run used an isolated background receiver. The user-facing check requires foreground focus; this run does not test that focus policy.")
        }
        report = result
        isRunning = false
        PlaybackCheckRouter.shared.release(owner: self)
        session = nil
        transport = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        status = interruption ?? (result.integrityPassed
            ? "Text and event checks passed. Review timing separately below."
            : "The received output differs from the plan. Review the results below.")
    }

    private static func currentInputSource() -> String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { return "Unknown" }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
}

struct PlaybackCheckReceiver: NSViewRepresentable {
    let controller: PlaybackCheckController

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = TrainingEditorFactory.make(text: "", placeholder: "The built-in test will type here.", size: NSSize(width: 700, height: 100))
        editor.allowsUndo = false
        editor.isEditable = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        scroll.documentView = editor
        controller.receiver = editor
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
