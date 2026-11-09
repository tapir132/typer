import AppKit
import Darwin
import Foundation

/// A process-lifetime lease, shared by Stable, Edge and local builds. The file
/// stays in place: removing a locked file would let another process lock a new
/// inode. The kernel releases the lease on normal exit or a crash.
final class ApplicationInstanceLease {
    enum Failure: Error { case alreadyRunning }
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(at url: URL) throws -> ApplicationInstanceLease {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw systemError() }
        var transferred = false
        defer { if !transferred { Darwin.close(descriptor) } }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw systemError() }
        guard status.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { throw Failure.alreadyRunning }
            throw systemError()
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0 else { throw systemError() }
        transferred = true
        return ApplicationInstanceLease(descriptor: descriptor)
    }

    private static func systemError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    deinit { Darwin.close(descriptor) }
}

@MainActor
enum ApplicationStartup {
    private static var lease: ApplicationInstanceLease?

    /// Must run before creating stores, registering shortcuts or starting the
    /// updater. Older copies have no lease, so also detect a launched peer.
    static func ensureSingleInstance() {
        guard lease == nil else { return }
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: "com.tapir132.typer")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
        if let existing = peers.first(where: \.isFinishedLaunching) {
            existing.activate(options: [.activateAllWindows])
            exit(EXIT_SUCCESS)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do { lease = try ApplicationInstanceLease.acquire(at: support.appendingPathComponent("Typer/instance.lock")) }
        catch ApplicationInstanceLease.Failure.alreadyRunning {
            // A simultaneous launch may not have registered its window yet.
            peers.first?.activate(options: [.activateAllWindows])
            exit(EXIT_SUCCESS)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Typer couldn’t open its data folder"
            alert.informativeText = "Your saved data has not been changed. \(error.localizedDescription)"
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            exit(EXIT_FAILURE)
        }
    }
}
