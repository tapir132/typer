import Foundation
import Sparkle
import Testing
@testable import Typer

struct UpdatePresentationTests {
    @Test func buildIdentityDistinguishesRebuildsAtTheSameCommit() throws {
        let older = AppBuildIdentity(info: ["CFBundleShortVersionString": "1.0.0-local.bffec45", "CFBundleVersion": "1788540000"])
        var info: [String: Any] = ["CFBundleShortVersionString": "1.0.0-local.bffec45", "CFBundleVersion": "1788722395",
                                   "TyperBuildDate": "2026-09-06T19:19:55Z", "TyperBuildHasLocalChanges": true]
        let current = AppBuildIdentity(info: info)
        info["TyperBuildDate"] = "2026-09-07T19:19:55Z"
        #expect(older.version == current.version)
        #expect(try #require(current.builtAt) > #require(older.builtAt))
        #expect(current.builtAt == ISO8601DateFormatter().date(from: "2026-09-06T19:19:55Z"))
        #expect(current.isLocal && current.hasUnpublishedChanges)
        #expect(current.originLabel.contains("unpublished"))
        let published = AppBuildIdentity(info: ["CFBundleShortVersionString": "1.1.0", "CFBundleVersion": "1788545750"])
        #expect(!published.isLocal && published.builtAt == nil)
        #expect(AppBuildIdentity(info: [:]).isLocal)
    }

    @Test func newerLocalBuildIsAnExplainedSuccessfulCheck() {
        // The feed and local values observed when investigating the missing update.
        #expect(SUStandardVersionComparator.default.compareVersion("1788722395", toVersion: "1788545750") == .orderedDescending)
        var summary = UpdateCheckSummary()
        summary.begin()
        summary.publishedVersion = "1.0.0-edge.bffec45"
        summary.noUpdate(reason: .onNewerThanLatestVersion, channel: .edge, localBuild: true)
        let checked = Date(timeIntervalSince1970: 1788722500)
        summary.finish(error: NSError(domain: SUSparkleErrorDomain, code: 1001), at: checked)
        #expect(!summary.isChecking && summary.checkedAt == checked)
        #expect(summary.message?.contains("local build is newer") == true)
        #expect(summary.publishedVersion == "1.0.0-edge.bffec45")
    }

    @Test func incompatibilityIsNotPresentedAsAlreadyCurrent() {
        var summary = UpdateCheckSummary()
        summary.noUpdate(reason: .systemIsTooOld, channel: .stable, localBuild: false)
        #expect(summary.message?.contains("requires a newer version of macOS") == true)
        summary.noUpdate(reason: .onLatestVersion, channel: .stable, localBuild: false)
        #expect(summary.message?.contains("latest published Release") == true)
        summary.noUpdate(reason: nil, channel: .edge, localBuild: true)
        #expect(summary.message?.contains("No compatible newer build") == true)
    }

    @Test func failedCheckCanRecoverToAnAvailableUpdate() {
        var summary = UpdateCheckSummary()
        summary.begin()
        summary.finish(error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
                                      userInfo: [NSLocalizedDescriptionKey: "Offline"]))
        #expect(summary.message == "Update check failed: Offline")
        #expect(!summary.isChecking && summary.checkedAt != nil)
        summary.begin()
        #expect(summary.isChecking && summary.publishedVersion == nil)
        summary.found(version: "1.2.0")
        summary.finish(error: nil)
        #expect(summary.message == "Update available: 1.2.0")
        #expect(summary.publishedVersion == "1.2.0")
    }
}
