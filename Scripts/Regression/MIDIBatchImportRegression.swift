import Foundation
import PianoLink

private enum BatchRegressionError: Error { case assertion(String), timeout }

@MainActor private final class BatchSender {
    struct Attempt { let file: LinkMIDIFile; let receiver: UUID }
    var attempts: [Attempt] = []
    var rejects: Set<String> = []
    var blockedTitles: Set<String> = []
    var disconnectAtAttempt: Int?
    var active = 0
    var maxActive = 0

    func send(_ file: LinkMIDIFile, receiver: UUID) async throws {
        active += 1
        maxActive = max(active, maxActive)
        defer { active -= 1 }
        attempts.append(Attempt(file: file, receiver: receiver))
        while blockedTitles.contains(file.title) { try await Task.sleep(for: .milliseconds(2)) }
        try Task.checkCancellation()
        if attempts.count == disconnectAtAttempt { throw MIDIFileTransferError.disconnected }
        if rejects.contains(file.title) { throw MIDIFileTransferError.rejected("fixture parsing/storage failure") }
    }
}

@main struct MIDIBatchImportRegression {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let good = Data(Array("MThd".utf8) + Array(repeating: UInt8(7), count: 24))
        let receiver = UUID()

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw BatchRegressionError.assertion(message) }
        }
        func write(_ relative: String, data: Data? = nil) throws -> URL {
            let url = root.appending(path: relative)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data ?? good).write(to: url)
            return url
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while !condition() {
                if ProcessInfo.processInfo.systemUptime >= deadline { throw BatchRegressionError.timeout }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        func idle(_ model: MIDIBatchImportModel) async throws { try await wait { !model.isScanning && !model.isSending } }
        func model(_ sender: BatchSender) -> MIDIBatchImportModel {
            MIDIBatchImportModel(sender: { file, receiver in try await sender.send(file, receiver: receiver) })
        }

        let folder = root.appending(path: "collection", directoryHint: .isDirectory)
        for file in ["B.mid", "a.MIDI", "Sub/a.mid", "Reject.mid", ".hidden.mid", ".hidden-dir/inside.mid", "Ignore.app/inside.mid"] {
            _ = try write("collection/\(file)")
        }
        _ = try write("collection/readme.txt")
        _ = try write("collection/empty.mid", data: Data())
        _ = try write("collection/invalid.mid", data: Data("NOPEfile".utf8))
        let oversized = try write("collection/large.mid")
        let large = try FileHandle(forWritingTo: oversized)
        try large.truncate(atOffset: UInt64(LinkMIDIFile.maximumByteCount + 1))
        try large.close()
        let outside = try write("outside/escape.mid")
        try manager.createSymbolicLink(at: folder.appending(path: "linked.mid"), withDestinationURL: outside)
        try manager.createSymbolicLink(at: folder.appending(path: "linked-dir"), withDestinationURL: outside.deletingLastPathComponent())

        let sender = BatchSender()
        sender.rejects = ["Reject"]
        let batch = model(sender)
        batch.selectFolder(folder)
        try await idle(batch)
        try expect(batch.items.map(\.relativePath) == ["a.MIDI", "B.mid", "empty.mid", "invalid.mid", "large.mid", "Reject.mid", "Sub/a.mid"],
                   "Recursive scan did not deterministically filter hidden, package and symbolic-link paths")
        try expect(sender.attempts.isEmpty && batch.canSend, "Selecting offline read or sent song contents")
        batch.send(to: receiver)
        try await idle(batch)
        try expect(batch.importedCount == 3 && batch.failedCount == 4 && sender.maxActive == 1,
                   "Per-file failures did not continue with strictly serial confirmation")
        try expect(sender.attempts.allSatisfy { !$0.file.activateOnImport && $0.receiver == receiver },
                   "Folder import activated a song or changed its selected receiver")
        try expect(batch.items.filter { $0.state.isFailure }.allSatisfy { $0.errorMessage != nil }, "Failures have no visible explanation")
        print("PASS: recursive, deterministic, metadata-only scan skips hidden/package/symlink paths")
        print("PASS: folder import is serial, library-only, bounded and continues after individual failures")

        let successfulIDs = Set(sender.attempts.filter { $0.file.title != "Reject" }.map { $0.file.importID! })
        let originalReject = sender.attempts.first { $0.file.title == "Reject" }!.file
        sender.rejects.removeAll()
        batch.send(to: receiver)
        try await idle(batch)
        let retriedReject = sender.attempts.last!.file
        try expect(batch.importedCount == 4 && batch.failedCount == 3 && sender.attempts.count == 5,
                   "Retry resent confirmed songs or lost remaining failures")
        try expect(retriedReject.importID == originalReject.importID && retriedReject.id != originalReject.id,
                   "Retry needs a stable logical import identity and a fresh transport identity")
        try expect(sender.attempts.filter { successfulIDs.contains($0.file.importID!) }.count == 3,
                   "Previously confirmed songs were sent twice to the same connection")
        print("PASS: retry preserves importID, refreshes transfer ID and skips confirmed songs")

        let only = try write("single/One.mid")
        let singleSender = BatchSender()
        let single = model(singleSender)
        single.selectFile(only)
        try await idle(single)
        single.send(to: receiver)
        try await idle(single)
        try expect(single.importedCount == 1 && singleSender.attempts[0].file.activateOnImport,
                   "Single-file selection did not keep activation behavior")
        try expect(!single.canSend(to: receiver), "Completed queue remains resendable to its existing connection")
        let other = UUID()
        try expect(single.canSend(to: other), "A completed queue cannot be sent to a different headset")
        single.send(to: other)
        try await idle(single)
        try expect(singleSender.attempts.count == 2 && singleSender.attempts.last!.receiver == other,
                   "New receiver did not get a complete queue")
        try expect(singleSender.attempts[0].file.importID == singleSender.attempts[1].file.importID,
                   "Reconnect lost logical identity required for receiver deduplication")
        print("PASS: single file activates; a changed receiver can reconfirm an already completed queue")

        let resumeRoot = root.appending(path: "resume", directoryHint: .isDirectory)
        for name in ["01.mid", "02.mid", "03.mid"] { _ = try write("resume/\(name)") }
        let resumeSender = BatchSender()
        resumeSender.blockedTitles = ["02"]
        let resume = model(resumeSender)
        resume.selectFolder(resumeRoot)
        try await idle(resume)
        resume.send(to: receiver)
        try await wait { resumeSender.attempts.count == 2 }
        try expect(resume.importedCount == 1 && resume.items[1].state == .sending,
                   "A song was marked imported before its sender returned")
        resume.cancel()
        try await idle(resume)
        try expect(resume.importedCount == 1 && resume.failedCount == 0 && resume.pendingCount == 2,
                   "Cancel discarded successful or unsent queue entries")
        resumeSender.blockedTitles.removeAll()
        resume.send(to: receiver)
        try await idle(resume)
        try expect(resume.importedCount == 3 && resumeSender.attempts.filter { $0.file.title == "01" }.count == 1,
                   "Same-connection resume repeated confirmed songs")
        print("PASS: cancel waits for the actual sender, retains receipts and resumes unsent songs")

        let disconnectSender = BatchSender()
        disconnectSender.disconnectAtAttempt = 2
        let disconnect = model(disconnectSender)
        disconnect.selectFolder(resumeRoot)
        try await idle(disconnect)
        disconnect.send(to: receiver)
        try await idle(disconnect)
        try expect(disconnectSender.attempts.count == 2 && disconnect.importedCount == 1 && disconnect.pendingCount == 1,
                   "Disconnect sent every remaining file instead of stopping promptly")
        disconnectSender.disconnectAtAttempt = nil
        let reconnected = UUID()
        disconnect.send(to: reconnected)
        try await idle(disconnect)
        try expect(disconnect.importedCount == 3 && disconnectSender.attempts.count == 5,
                   "A new connection did not receive/reconfirm the whole queue")
        try expect(disconnectSender.attempts.suffix(3).allSatisfy { $0.receiver == reconnected },
                   "A resumed queue mixed receiver identities")
        print("PASS: disconnect stops pending sends; a replacement connection reconfirms the full batch")

        let lazyRoot = root.appending(path: "lazy", directoryHint: .isDirectory)
        _ = try write("lazy/01.mid")
        let changed = try write("lazy/02.mid")
        let lazySender = BatchSender()
        lazySender.blockedTitles = ["01"]
        let lazy = model(lazySender)
        lazy.selectFolder(lazyRoot)
        try await idle(lazy)
        lazy.send(to: receiver)
        try await wait { lazySender.attempts.count == 1 }
        var newBytes = good
        newBytes[newBytes.count - 1] = 99
        try newBytes.write(to: changed)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: changed.path)
        lazySender.blockedTitles.removeAll()
        try await idle(lazy)
        try expect(lazySender.attempts.count == 1 && lazy.failedCount == 1 && lazy.items[1].errorMessage?.contains("重新选择") == true,
                   "Songs were prefetched or changed contents reused an earlier importID")
        lazy.send(to: receiver)
        try await idle(lazy)
        try expect(lazySender.attempts.count == 1, "Retry accepted changed content under the old logical identity")
        lazy.selectFolder(lazyRoot)
        try await idle(lazy)
        lazy.send(to: receiver)
        try await idle(lazy)
        try expect(lazy.importedCount == 2, "Explicit re-selection did not permit new source contents")
        print("PASS: songs are read lazily and changed size/mtime/inode requires explicit re-selection")

        let replaced = try write("replace/One.mid")
        let replacementSender = BatchSender()
        let replacement = model(replacementSender)
        replacement.selectFile(replaced)
        try await idle(replacement)
        try manager.removeItem(at: replaced)
        try manager.createSymbolicLink(at: replaced, withDestinationURL: outside)
        replacement.send(to: receiver)
        try await idle(replacement)
        try expect(replacement.failedCount == 1 && replacementSender.attempts.isEmpty, "File replaced by a symlink was followed")
        let ancestor = try write("ancestor/Nested/One.mid")
        let ancestorModel = model(replacementSender)
        ancestorModel.selectFolder(root.appending(path: "ancestor", directoryHint: .isDirectory))
        try await idle(ancestorModel)
        try manager.removeItem(at: ancestor.deletingLastPathComponent())
        try manager.createSymbolicLink(at: ancestor.deletingLastPathComponent(), withDestinationURL: outside.deletingLastPathComponent())
        ancestorModel.send(to: receiver)
        try await idle(ancestorModel)
        try expect(ancestorModel.failedCount == 1 && replacementSender.attempts.isEmpty, "Changed folder ancestor escaped the selected root")
        print("PASS: replaced file and ancestor symlinks are rejected again at read time")

        let stoppingSender = BatchSender()
        stoppingSender.blockedTitles = ["One"]
        let stopping = model(stoppingSender)
        stopping.selectFile(only)
        try await idle(stopping)
        stopping.send(to: receiver)
        try await wait { stoppingSender.active == 1 }
        stopping.stop()
        try await wait { stoppingSender.active == 0 }
        try expect(stopping.items.isEmpty && !stopping.isSending && !stopping.isScanning,
                   "Stopped task restored old selection or retained busy state")
        stoppingSender.blockedTitles.removeAll()
        stopping.selectFile(only)
        try await idle(stopping)
        stopping.send(to: receiver)
        try await idle(stopping)
        try expect(stopping.importedCount == 1, "A late cancelled sender corrupted the new selection")
        print("PASS: stop during an active sender cannot mutate a new queue or revoke in-flight lease ownership")

        let empty = root.appending(path: "empty", directoryHint: .isDirectory)
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)
        let selection = model(BatchSender())
        selection.selectFolder(empty)
        try await idle(selection)
        try expect(selection.items.isEmpty && selection.status.contains("没有找到") && !selection.canSend, "Empty folder was not explained")
        selection.selectFolder(folder)
        await Task.yield()
        selection.selectFile(only)
        try await idle(selection)
        try expect(selection.items.map(\.relativePath) == ["One.mid"], "Stale detached scan replaced a newer file selection")
        selection.selectionFailed(CocoaError(.userCancelled))
        try expect(selection.items.count == 1, "Closing the picker cleared a valid queue")
        selection.selectionFailed(CocoaError(.fileReadNoSuchFile))
        try expect(selection.items.isEmpty && selection.status.contains("失败"), "Selection failure left a hidden stale send target")
        print("PASS: empty/error selections and cancelled/replaced detached scans stay visible and isolated")

        for value in [batch, single, resume, disconnect, lazy, replacement, ancestorModel, stopping, selection] { value.stop() }
        print("PASS: all 10 batch-import regression groups completed")
    }
}
