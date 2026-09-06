import Combine
import Sparkle

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case edge

    var id: String { rawValue }
    var title: String { self == .stable ? "Release" : "Edge" }
}

struct StartupUpdatePromptGate {
    private(set) var isPending = false

    mutating func queue() { isPending = true }

    mutating func consumeIfReady(canCheck: Bool, sessionInProgress: Bool) -> Bool {
        guard isPending, canCheck, !sessionInProgress else { return false }
        isPending = false
        return true
    }
}

enum UpdateErrorPresentation {
    static let noUpdateErrorCode = 1001 // Sparkle's SUNoUpdateError

    static func message(for error: NSError?) -> String? {
        guard let error else { return nil }
        guard !(error.domain == SUSparkleErrorDomain && error.code == noUpdateErrorCode) else { return nil }
        let recovery = error.localizedRecoverySuggestion?.trimmingCharacters(in: .whitespacesAndNewlines)
        return [error.localizedDescription, recovery]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Sparkle owns feed verification, update scheduling, atomic replacement, and
/// relaunching. Typer only exposes the user's update preferences and channel.
@MainActor
final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let shared = UpdateManager()

    private static let stableFeed = "https://github.com/tapir132/typer/releases/latest/download/appcast.xml"
    private static let edgeFeed = "https://github.com/tapir132/typer/releases/download/edge/appcast.xml"

    lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastError: String?
    @Published private(set) var checkSummary = UpdateCheckSummary()
    // Capture metadata at launch; rebuilding the .app on disk must not make an
    // already-running process claim to be the replacement binary.
    let build = AppBuildIdentity(info: Bundle.main.infoDictionary ?? [:])
    @Published var channel: UpdateChannel = .stable {
        didSet {
            guard isConfigured else { return }
            UserDefaults.standard.set(channel.rawValue, forKey: "updateChannel")
            checkSummary = UpdateCheckSummary()
            lastError = nil
            if hasStarted { controller.updater.resetUpdateCycleAfterShortDelay() }
        }
    }
    @Published var automaticallyChecks = true {
        didSet {
            guard isConfigured else { return }
            controller.updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }
    @Published var automaticallyDownloads = false {
        didSet {
            guard isConfigured else { return }
            controller.updater.automaticallyDownloadsUpdates = automaticallyDownloads
        }
    }

    private var isConfigured = false
    private var hasStarted = false
    private var startupProbeInProgress = false
    private var startupProbeFoundUpdate = false
    private var startupPromptGate = StartupUpdatePromptGate()
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
        if let saved = UserDefaults.standard.string(forKey: "updateChannel"), let savedChannel = UpdateChannel(rawValue: saved) {
            channel = savedChannel
        }
        automaticallyChecks = controller.updater.automaticallyChecksForUpdates
        automaticallyDownloads = controller.updater.automaticallyDownloadsUpdates
        canCheckForUpdates = controller.updater.canCheckForUpdates
        isConfigured = true

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] available in
                guard let self else { return }
                self.canCheckForUpdates = available
                if available { self.presentStartupUpdateIfReady() }
            }
            .store(in: &cancellables)
    }

    func start() {
        guard !hasStarted, Bundle.main.bundleURL.pathExtension == "app" else { return }
        hasStarted = true
        controller.updater.clearFeedURLFromUserDefaults()
        controller.startUpdater()

        guard controller.updater.automaticallyChecksForUpdates else { return }
        startupProbeInProgress = true
        startupProbeFoundUpdate = false
        controller.updater.checkForUpdateInformation()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        lastError = nil
        checkSummary.begin()
        controller.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        lastError = nil
        checkSummary.begin()
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        checkSummary.found(version: item.displayVersionString)
        if startupProbeInProgress { startupProbeFoundUpdate = true }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let error = error as NSError
        if let item = error.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem {
            checkSummary.publishedVersion = item.displayVersionString
        }
        let raw = (error.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.int32Value
        checkSummary.noUpdate(reason: raw.flatMap(SPUNoUpdateFoundReason.init(rawValue:)), channel: channel, localBuild: build.isLocal)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        checkSummary.finish(error: error as NSError?)
        if let error {
            let updateError = error as NSError
            if let detail = UpdateErrorPresentation.message(for: updateError) {
                lastError = detail
                NSLog("Typer Sparkle update failed: %@", updateError.debugDescription)
            } else {
                // Sparkle reports "already current" through its error callback.
                // It is a successful check result, not something to show in red.
                lastError = nil
            }
        } else {
            lastError = nil
        }
        guard startupProbeInProgress, updateCheck == .updateInformation else { return }
        let shouldPrompt = startupProbeFoundUpdate
        startupProbeInProgress = false
        startupProbeFoundUpdate = false
        guard shouldPrompt else { return }
        startupPromptGate.queue()
        presentStartupUpdateIfReady()
    }

    private func presentStartupUpdateIfReady() {
        guard startupPromptGate.consumeIfReady(
            canCheck: controller.updater.canCheckForUpdates,
            sessionInProgress: controller.updater.sessionInProgress
        ) else { return }
        controller.checkForUpdates(nil)
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        channel == .edge ? Self.edgeFeed : Self.stableFeed
    }
}
