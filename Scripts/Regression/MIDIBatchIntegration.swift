import Foundation
import PianoCore
import PianoLink

private enum IntegrationFailure: LocalizedError {
    case assertion(String), timeout
    var errorDescription: String? {
        switch self {
        case .assertion(let message): message
        case .timeout: "Timed out waiting for the batch transport"
        }
    }
}

@main struct MIDIBatchIntegration {
    @MainActor static func main() async throws {
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw IntegrationFailure.assertion(message) }
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while !condition() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw IntegrationFailure.timeout }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let folder = root.appending(path: "folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "nested"), withIntermediateDirectories: true)
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        for path in ["A.mid", "B.mid", "nested/C.MIDI"] { try data.write(to: folder.appending(path: path)) }
        let receiver = PianoSession(libraryDirectory: root.appending(path: "library"), loadsDemo: false, now: { 400 })
        let server = BridgeServer()
        let queue = MIDIBatchImportModel { file, peer in try await server.sendMIDIFile(file, to: peer) }
        defer { queue.stop(); receiver.bridge.disconnect(); server.stop() }
        server.start()
        try await wait { server.port != 0 }
        receiver.bridge.connect(host: "127.0.0.1", port: server.port)
        try await wait { receiver.bridge.latencyMilliseconds != nil && server.connectedClients.count == 1 }
        let peer = server.connectedClients[0].id
        let practice = PianoSong(title: "Keep this practice", notes: [
            .init(id: 0, pitch: 60, start: 0, duration: 1),
            .init(id: 1, pitch: 64, start: 0, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano")])
        receiver.install(practice)
        receiver.play()
        receiver.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: 400))
        let revision = receiver.songRevision
        var attempts: [LinkMIDIFile] = []
        var dropFirstBReceipt = true
        receiver.bridge.onMIDIFile = { file in
            attempts.append(file)
            try await receiver.importMIDIFile(file)
            // Model an uncertain outcome: durable import succeeded but the sender
            // sees a failure instead of a success receipt for this attempt.
            if file.title == "B" && dropFirstBReceipt {
                dropFirstBReceipt = false
                throw IntegrationFailure.assertion("Simulated missing success receipt")
            }
        }
        queue.selectFolder(folder)
        try await wait { !queue.isScanning }
        try expect(queue.items.count == 3, "Folder did not include the nested uppercase extension")
        queue.send(to: peer)
        try await wait { !queue.isSending }
        try expect(queue.importedCount == 2 && queue.failedCount == 1 && attempts.count == 3,
                   "A per-file failure prevented later MIDI files from being imported")
        try expect(receiver.library.count == 3, "A success receipt was assumed to mean a commit had not occurred")
        let libraryIDs = Set(receiver.library.map(\.id))
        queue.send(to: peer)
        try await wait { !queue.isSending }
        try expect(queue.importedCount == 3 && queue.failedCount == 0 && attempts.count == 4,
                   "Retry resent already confirmed files or failed to retry the uncertain item")
        try expect(receiver.library.count == 3 && Set(receiver.library.map(\.id)) == libraryIDs,
                   "Retry after a lost success receipt created a duplicate library entry")
        let firstB = attempts.first { $0.title == "B" }!
        let retryB = attempts.last!
        try expect(firstB.id != retryB.id && firstB.importID != nil && firstB.importID == retryB.importID,
                   "Transfer attempts must have new IDs while keeping the queue-item import identity")
        try expect(attempts.allSatisfy { !$0.activateOnImport }, "A folder item requested active-song replacement")
        try expect(receiver.song == practice && receiver.songRevision == revision && receiver.isPlaying
                   && receiver.isWaiting && receiver.matchedWaitingPitches == [60] && receiver.activeNotes == [60],
                   "Batch transfer interrupted the current partial chord or replaced the current song")
        for entry in receiver.library {
            let saved = try Data(contentsOf: root.appending(path: "library").appending(path: entry.fileName))
            try expect(saved == data, "A confirmed import was not durably saved byte for byte")
        }
        print("PASS: real folder queue → TCP → receiver parsing and durable library storage")
        print("PASS: per-file failure continues; retry skips successes and deduplicates an uncertain commit")
        print("PASS: batch imports preserve the current song, playback intent and partial physical chord")
    }
}
