import Foundation
import Sparkle

struct AppBuildIdentity: Equatable {
    let version: String
    let number: String
    let isLocal: Bool
    let builtAt: Date?
    let hasUnpublishedChanges: Bool

    init(info: [String: Any]) {
        version = info["CFBundleShortVersionString"] as? String ?? "Development"
        number = info["CFBundleVersion"] as? String ?? ""
        isLocal = version.contains("-local.") || version == "Development"
        if let timestamp = info["TyperBuildDate"] as? String {
            builtAt = ISO8601DateFormatter().date(from: timestamp)
        } else if isLocal, let timestamp = Double(number), timestamp > 1_000_000_000 {
            builtAt = Date(timeIntervalSince1970: timestamp)
        } else { builtAt = nil }
        hasUnpublishedChanges = info["TyperBuildHasLocalChanges"] as? Bool ?? false
    }

    var originLabel: String {
        if hasUnpublishedChanges { return "Local build · includes unpublished changes" }
        return isLocal ? "Local development build" : "Published build"
    }
}

struct UpdateCheckSummary: Equatable {
    var isChecking = false
    var checkedAt: Date?
    var message: String?
    var publishedVersion: String?

    mutating func begin() {
        isChecking = true
        message = "Checking for a published update…"
        publishedVersion = nil
    }

    mutating func found(version: String) {
        publishedVersion = version
        message = "Update available: \(version)"
    }

    mutating func noUpdate(reason: SPUNoUpdateFoundReason?, channel: UpdateChannel, localBuild: Bool) {
        switch reason {
        case .onLatestVersion:
            message = "You're on the latest published \(channel.title) build."
        case .onNewerThanLatestVersion:
            message = localBuild
                ? "This local build is newer than the latest published \(channel.title) build."
                : "This build is newer than the latest published \(channel.title) build."
        case .systemIsTooOld:
            message = "The latest update requires a newer version of macOS."
        case .systemIsTooNew:
            message = "The latest update does not support this version of macOS."
        case .hardwareDoesNotSupportARM64:
            message = "The latest update requires Apple silicon."
        default:
            message = "No compatible newer build was found on \(channel.title)."
        }
    }

    mutating func finish(error: NSError?, at date: Date = Date()) {
        isChecking = false
        checkedAt = date
        if let detail = UpdateErrorPresentation.message(for: error) { message = "Update check failed: \(detail)" }
        else if message == nil || message == "Checking for a published update…" {
            message = "Update check completed. No compatible newer build was offered."
        }
    }
}
