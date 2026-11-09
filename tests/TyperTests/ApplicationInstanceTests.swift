import Darwin
import Foundation
import Testing
@testable import Typer

struct ApplicationInstanceTests {
    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("typer-instance-tests-\(UUID())/private/instance.lock")
    }

    @Test func onlyOneLeaseCanOwnTheSameDataFolderAndClosingItAllowsRelaunch() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        var first: ApplicationInstanceLease? = try .acquire(at: url)
        #expect(first != nil)
        #expect(throws: ApplicationInstanceLease.Failure.alreadyRunning) { try ApplicationInstanceLease.acquire(at: url) }
        first = nil
        let next = try ApplicationInstanceLease.acquire(at: url)
        withExtendedLifetime(next) {
            #expect(throws: ApplicationInstanceLease.Failure.alreadyRunning) { try ApplicationInstanceLease.acquire(at: url) }
            return ()
        }
    }

    @Test func staleFileIsReusedWithoutReplacingItsInodeAndPermissionsArePrivate() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data("stale metadata is not a live lock".utf8).write(to: url)
        let original = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber
        let lease = try ApplicationInstanceLease.acquire(at: url)
        try withExtendedLifetime(lease) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.systemFileNumber] as? NSNumber == original)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            #expect(String(data: try Data(contentsOf: url), encoding: .utf8) == "stale metadata is not a live lock")
        }
    }

    @Test func separateDataFoldersDoNotBlockEachOther() throws {
        let firstURL = location(), secondURL = location()
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent().deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent().deletingLastPathComponent())
        }
        let first = try ApplicationInstanceLease.acquire(at: firstURL)
        let second = try ApplicationInstanceLease.acquire(at: secondURL)
        withExtendedLifetime((first, second)) {}
    }

    @Test func unsafePathsAndUnwritableLocationsDoNotSilentlyDisableProtection() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let root = url.deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("kept.json")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        #expect(throws: (any Error).self) { try ApplicationInstanceLease.acquire(at: url) }
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
        #expect(throws: (any Error).self) { try ApplicationInstanceLease.acquire(at: target.appendingPathComponent("lock")) }
    }
}
