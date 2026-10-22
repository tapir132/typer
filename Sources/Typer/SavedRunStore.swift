import CryptoKit
import Darwin
import Foundation

struct SavedFieldState: Codable, Equatable {
    var documentDigest: String
    var selection: NSRange

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct SavedTypingRun: Codable, Equatable, Identifiable {
    var version = 1
    var id = UUID()
    var savedAt = Date()
    var context: TypingRunContext
    var plan: TypingPlan
    var checkpoint: PlaybackCheckpoint
    var layoutIdentifier: String
    var actions: [PhysicalKeyAction]
    var targetBundleIdentifier: String?
    var targetName: String
    var field: SavedFieldState?

    var progress: PlaybackProgress {
        PlaybackProgress(fraction: Double(checkpoint.nextAction) / Double(max(1, actions.count)),
                         remaining: max(0, plan.duration / 1_000 - checkpoint.elapsed), isPaused: true)
    }

    var typedBuffer: PreviewTextBuffer {
        var buffer = PreviewTextBuffer()
        for action in actions.prefix(checkpoint.nextAction) where action.isDown {
            if let index = action.eventIndex, plan.events.indices.contains(index) { buffer.apply(plan.events[index]) }
        }
        return buffer
    }

    var cursorHint: String {
        let buffer = typedBuffer
        let text = buffer.text as NSString
        let range = buffer.selectedRange
        let before = String(text.substring(to: range.location).suffix(50))
        let after = String(text.substring(from: NSMaxRange(range)).prefix(35))
        if range.length > 0 { return "Select right to left: …\(before)[\(String(text.substring(with: range).prefix(80)))]\(after)…" }
        return "Cursor: \(before.isEmpty ? "" : "…")\(before)│\(after)"
    }

    // AX ranges do not preserve selection direction. If we stopped midway
    // through selecting a word, restore the anchor and replay that non-text
    // selection block. This works even after the target app has relaunched.
    private var selectionReplayIndex: Int? {
        guard let field, field.selection.length > 0,
              let previous = actions.prefix(checkpoint.nextAction).last(where: { $0.isDown && $0.eventIndex != nil })?.eventIndex,
              let next = actions.dropFirst(checkpoint.nextAction).first(where: { $0.isDown && $0.eventIndex != nil })?.eventIndex,
              next == previous + 1, plan.events[previous].kind == .shiftArrowLeft,
              plan.events[next].kind == .shiftArrowLeft else { return nil }
        var first = previous
        while first > 0 && plan.events[first - 1].kind == .shiftArrowLeft { first -= 1 }
        return actions.firstIndex { $0.ownerIndex == first }
    }

    var resumeCheckpoint: PlaybackCheckpoint {
        guard let index = selectionReplayIndex else { return checkpoint }
        return PlaybackCheckpoint(nextAction: index, elapsed: min(checkpoint.elapsed, (actions[index].scheduledOffset ?? 0) / 1_000))
    }

    var resumeField: SavedFieldState? {
        guard var field, selectionReplayIndex != nil else { return field }
        field.selection = NSRange(location: NSMaxRange(field.selection), length: 0)
        return field
    }

    /// A changed layout or scheduler must never reinterpret an old physical
    /// cursor as a different sequence of key presses.
    func isCompatible(with layout: KeyboardLayout) -> Bool {
        layout.identifier == layoutIdentifier && KeyTimeline.physicalActions(for: plan.events, layout: layout) == actions
    }

    func validate() throws {
        guard version == 1, !plan.events.isEmpty, plan.events.count <= 500_000,
              context.text.utf8.count <= 4_000_000, !context.text.isEmpty,
              plan.duration.isFinite, plan.duration > 0, plan.duration <= 1_000_000_000_000,
              actions.last?.scheduledOffset == plan.duration,
              checkpoint.elapsed.isFinite, checkpoint.elapsed >= 0, checkpoint.elapsed <= plan.duration / 1_000 + 0.001,
              actions.count <= 3_000_000, (0..<actions.count).contains(checkpoint.nextAction),
              checkpoint.rewindOwner.map({ plan.events.indices.contains($0) }) ?? true,
              !layoutIdentifier.isEmpty, layoutIdentifier.count <= 512, targetName.count <= 512,
              targetBundleIdentifier.map({ !$0.isEmpty && $0.count <= 512 }) ?? true,
              plan.events.allSatisfy({ $0.flight.isFinite && $0.dwell.isFinite }),
              actions.allSatisfy({ action in
                  action.scheduledOffset.map { $0.isFinite && $0 >= 0 && $0 <= plan.duration + 1_000 } == true &&
                  plan.events.indices.contains(action.ownerIndex) &&
                  (action.eventIndex.map { plan.events.indices.contains($0) } ?? true)
              }) else { throw SavedRunError.invalid }
        if let field {
            guard field.documentDigest.count == 64, field.selection.location >= 0, field.selection.length >= 0,
                  field.selection.location <= Int.max - field.selection.length else { throw SavedRunError.invalid }
        }
    }
}

enum SavedRunError: LocalizedError {
    case invalid, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: return "The saved run is damaged or uses a different format. Its file has been kept."
        case .tooLarge: return "This run is too large to save. Pause can still keep it open in Typer."
        }
    }
}

/// One explicitly saved run, local to this Mac. Tests inject a private temporary
/// URL (or nil for an in-memory store), so they never open the user's saved text.
@MainActor
final class SavedRunStore {
    let url: URL?
    private var memory: SavedTypingRun?
    private let maximumBytes = 64 * 1_024 * 1_024

    static func applicationStore() -> SavedRunStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SavedRunStore(url: support.appendingPathComponent("Typer/Saved Runs/current.json"))
    }

    init(url: URL?) { self.url = url }

    var hasStoredRun: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? (memory != nil) }

    func load() throws -> SavedTypingRun? {
        guard let url else { return memory }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maximumBytes else { throw SavedRunError.tooLarge }
        let run: SavedTypingRun
        do { run = try JSONDecoder().decode(SavedTypingRun.self, from: Data(contentsOf: url)) }
        catch { throw SavedRunError.invalid }
        try run.validate()
        return run
    }

    func save(_ run: SavedTypingRun) throws {
        try run.validate()
        guard let url else { memory = run; return }
        let data = try JSONEncoder().encode(run)
        guard data.count <= maximumBytes else { throw SavedRunError.tooLarge }
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func remove() throws {
        if let url, FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        memory = nil
    }
}
