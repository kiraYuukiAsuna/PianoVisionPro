import Foundation
import PianoCore
import PianoLink

private enum RegressionFailure: Error { case assertion(String) }

@main struct PianoSessionRegression {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

        func makeSession(_ name: String) -> PianoSession {
            PianoSession(libraryDirectory: root.appending(path: name, directoryHint: .isDirectory), loadsDemo: false)
        }
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            if !condition() { throw RegressionFailure.assertion(message) }
        }
        func send(_ bytes: [UInt8], to session: PianoSession) {
            var decoder = MIDIByteDecoder()
            for event in decoder.decode(bytes, timestamp: ProcessInfo.processInfo.systemUptime) {
                session.receive(event)
            }
        }

        let selected = makeSession("filtered")
        selected.inputChannel = 0
        send([0x90, 60, 100, 0xB0, 64, 127], to: selected)
        for controller in [120, 123] {
            send([0xB1, UInt8(controller), 0], to: selected)
            try expect(selected.activeNotes == [60], "An excluded channel cleared the selected channel's key")
            try expect(selected.pedalDown, "An excluded channel cleared the selected channel's pedal")
        }
        print("PASS: channel-filtered CC120/123 preserve held key and pedal")

        let channels = makeSession("all-channels")
        send([0x90, 60, 100, 0x91, 64, 100, 0xB0, 64, 127], to: channels)
        send([0xB1, 123, 0], to: channels)
        try expect(channels.activeNotes == [60], "CC123 cleared a different channel")
        try expect(channels.pedalDown, "CC123 reset a different channel's pedal")
        print("PASS: CC123 clears only its own channel")

        send([0xB0, 123, 0], to: channels)
        try expect(channels.activeNotes.isEmpty, "CC123 failed to release physical key state")
        try expect(channels.pedalDown, "CC123 incorrectly reset the sustain controller")
        print("PASS: CC123 releases keys without resetting pedal state")

        send([0x90, 60, 100, 0x91, 67, 100, 0xB1, 120, 0], to: channels)
        try expect(channels.activeNotes == [60], "CC120 cleared a different channel")
        try expect(channels.pedalDown, "CC120 incorrectly reset another channel's pedal")
        print("PASS: CC120 clears only its own channel")

        channels.bridge.onReset?()
        try expect(channels.activeNotes.isEmpty && !channels.pedalDown, "Bridge reset failed to clear all input state")
        print("PASS: bridge reset remains global")

        var seekHost = 80.0
        let seeking = PianoSession(libraryDirectory: root.appending(path: "seek-boundary"), loadsDemo: false, now: { seekHost })
        seeking.setPracticeMode(.automatic)
        seeking.install(PianoSong(title: "Seek boundary", notes: [
            PianoNote(id: 0, pitch: 60, start: 9.8, duration: 0.05),
            PianoNote(id: 1, pitch: 64, start: 10, duration: 1)
        ], tracks: [SongTrack(id: 0, name: "Piano")]))
        seeking.play()
        seeking.seek(to: 10)
        seekHost += 3
        seeking.receive(.init(kind: .noteOn, note: 64, velocity: 100, timestamp: seekHost))
        try expect(seeking.hitCount == 1 && seeking.wrongCount == 0,
                   "Seeking during playback skipped a target exactly at the selected time")
        print("PASS: live seek preserves a target exactly at the selected boundary")

        let waiting = makeSession("wait-chord")
        waiting.install(PianoSong(title: "Wait for chord", notes: [
            PianoNote(id: 0, pitch: 60, start: 0, duration: 0.2),
            PianoNote(id: 1, pitch: 64, start: 0, duration: 0.2),
            PianoNote(id: 2, pitch: 67, start: 0, duration: 0.2),
            PianoNote(id: 3, pitch: 60, start: 0.02, duration: 0.2)
        ], tracks: [SongTrack(id: 0, name: "Piano")]))
        waiting.inputOffsetMilliseconds = 150
        waiting.play()
        send([0x90, 60, 100, 64, 100], to: waiting)
        waiting.updatePractice()
        try expect(waiting.isPlaying && waiting.isWaiting && waiting.hitCount == 0,
                   "A partial chord advanced playback or cleared playback intent")
        try expect(waiting.songTime == 0 && waiting.matchedWaitingPitches == [60, 64],
                   "Partial chord state did not stay on the target")
        send([0x90, 67, 100], to: waiting)
        try expect(waiting.hitCount == 3 && waiting.isPlaying,
                   "A completed chord failed to resume immediately")
        print("PASS: partial chord waits and full chord resumes without fixed buffer delay")
        try await Task.sleep(for: .milliseconds(40))
        waiting.updatePractice()
        try expect(waiting.isWaiting && waiting.songTime == 0.02, "The next target was skipped")
        send([0x90, 60, 100], to: waiting)
        try expect(waiting.hitCount == 3, "A held repeated pitch satisfied a new onset")
        send([0x80, 60, 0, 0x90, 60, 100], to: waiting)
        try expect(waiting.hitCount == 4 && waiting.missedCount == 0, "A repeated note did not require release/restrike")
        print("PASS: repeated targets require a new strike and wait mode does not count misses")

        waiting.restart()
        waiting.play()
        send([0x90, 64, 100], to: waiting)
        waiting.bridge.onReset?()
        try expect(!waiting.isPlaying && waiting.activeNotes.isEmpty && waiting.matchedWaitingPitches.isEmpty,
                   "Disconnect retained a chord attempt or continued playing")
        print("PASS: bridge reset pauses wait playback and clears its partial chord")

        let scopedReset = makeSession("wait-channel-reset")
        scopedReset.install(PianoSong(title: "Channel reset", notes: [
            PianoNote(id: 0, pitch: 60, start: 0, duration: 0.2),
            PianoNote(id: 1, pitch: 64, start: 0, duration: 0.2)
        ], tracks: [SongTrack(id: 0, name: "Piano")]))
        scopedReset.play()
        send([0x90, 60, 100], to: scopedReset)
        send([0xB1, 123, 0], to: scopedReset)
        send([0x90, 60, 100, 64, 100], to: scopedReset)
        try expect(scopedReset.hitCount == 0 && scopedReset.matchedWaitingPitches == [64],
                   "A channel reset allowed a key held on another channel to count as a fresh onset")
        send([0x80, 60, 0, 0x90, 60, 100], to: scopedReset)
        try expect(scopedReset.hitCount == 2, "Channel reset did not allow a genuine release/restrike")
        scopedReset.restart()
        scopedReset.setTrack(0, enabled: true)
        scopedReset.play()
        send([0x90, 60, 100, 64, 100], to: scopedReset)
        try expect(scopedReset.hitCount == 0, "Rebuilding track targets forgot physically held pitches")
        print("PASS: channel reset and track rebuild preserve physical held-key history")

        var host = 100.0
        let ending = PianoSession(libraryDirectory: root.appending(path: "wait-zero-ending"), loadsDemo: false, now: { host })
        ending.install(PianoSong(title: "Zero-duration ending", notes: [
            PianoNote(id: 0, pitch: 60, start: 0, duration: 0.01),
            PianoNote(id: 1, pitch: 64, start: 0.05, duration: 0)
        ], tracks: [SongTrack(id: 0, name: "Piano")]))
        ending.play()
        ending.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: host))
        host += 0.1
        ending.updatePractice()
        try expect(ending.songTime == 0.05 && ending.waitingPitches == [64] && ending.hitCount == 1,
                   "The final zero-duration target was skipped")
        ending.pause()
        host += 1
        ending.play()
        try expect(ending.songTime == 0.05 && ending.waitingPitches == [64] && ending.hitCount == 1,
                   "Resuming a pending final target restarted the song or cleared its score")
        ending.receive(.init(kind: .noteOn, note: 64, velocity: 100, timestamp: host))
        ending.updatePractice()
        try expect(ending.hitCount == 2 && !ending.isPlaying, "The final zero-duration target failed to finish")
        ending.play()
        try expect(ending.songTime == 0 && ending.hitCount == 0 && ending.waitingPitches == [60],
                   "A genuinely completed song failed to restart")
        print("PASS: final zero-duration target resumes in place, completed song restarts")

        for zeroVelocity in [false, true] {
            var earlyHost = 200.0
            let early = PianoSession(libraryDirectory: root.appending(path: "early-release-\(zeroVelocity)"),
                                     loadsDemo: false, now: { earlyHost })
            early.install(PianoSong(title: "Early staccato", notes: [
                PianoNote(id: 0, pitch: 60, start: 1, duration: 0.05)
            ], tracks: [SongTrack(id: 0, name: "Piano")]))
            early.play()
            earlyHost = 200.99
            early.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: earlyHost))
            earlyHost = 201.01
            early.receive(.init(kind: zeroVelocity ? .noteOn : .noteOff, note: 60, velocity: 0, timestamp: earlyHost))
            try expect(early.hitCount == 1 && early.activeNotes.isEmpty && early.correctNotes == [60],
                       "Early staccato was lost before a frame, or its NoteOff completion was not scored")
            earlyHost = 201.02
            early.updatePractice()
            try expect(early.hitCount == 1 && !early.isWaiting, "A frame duplicated the completed staccato score")
            print("PASS: early staccato completes once before a frame (zero velocity: \(zeroVelocity))")
        }

        for nextPitch in [64, 62] {
            var melodyHost = 300.0
            let melody = PianoSession(libraryDirectory: root.appending(path: "early-next-\(nextPitch)"),
                                      loadsDemo: false, now: { melodyHost })
            melody.install(PianoSong(title: "Early melody", notes: [
                PianoNote(id: 0, pitch: 60, start: 1, duration: 0.2),
                PianoNote(id: 1, pitch: 64, start: 1.1, duration: 0.2)
            ], tracks: [SongTrack(id: 0, name: "Piano")]))
            melody.play()
            melodyHost = 300.95
            melody.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: melodyHost))
            melodyHost = 301.01
            melody.receive(.init(kind: .noteOn, note: nextPitch, velocity: 100, timestamp: melodyHost))
            try expect(melody.hitCount == 1 && melody.wrongCount == (nextPitch == 62 ? 1 : 0),
                       "A new input's judgement hid the preceding target's completion")
            melodyHost = 301.12
            melody.updatePractice()
            if nextPitch == 64 {
                try expect(melody.hitCount == 2 && !melody.isWaiting, "The next legal early onset was swallowed")
            } else {
                try expect(melody.hitCount == 1 && melody.isWaiting && melody.waitingPitches == [64],
                           "A wrong onset satisfied the next target")
                melody.receive(.init(kind: .noteOn, note: 64, velocity: 100, timestamp: melodyHost))
                try expect(melody.hitCount == 2 && melody.wrongCount == 1, "Retry lost or duplicated a completed target")
            }
            print("PASS: prior completion and next input are scored independently (pitch: \(nextPitch))")
        }

        let annotated = makeSession("annotations")
        let annotatedSong = PianoSong(title: "Hand and fingering", notes: [
            PianoNote(id: 0, pitch: 48, start: 0, duration: 0.2),
            PianoNote(id: 1, pitch: 72, start: 0.4, duration: 0.2)
        ], tracks: [SongTrack(id: 0, name: "Piano")])
        annotated.install(annotatedSong, storageKey: "regression")
        try expect(annotated.hand(for: annotatedSong.notes[0]) == .left && annotated.hand(for: annotatedSong.notes[1]) == .right,
                   "Single-track automatic hand split failed")
        annotated.setHand(.unassigned, forTrack: 0)
        try expect(annotated.hand(for: annotatedSong.notes[0]) == .unassigned, "Explicit neutral assignment was ignored")
        annotated.setHand(.left, forTrack: 0)
        annotated.showFingering = true
        annotated.setFinger(3, for: 0)
        for _ in 0..<200 where annotated.isGeneratingFingering { try await Task.sleep(for: .milliseconds(5)) }
        try expect(!annotated.isGeneratingFingering && annotated.finger(for: annotatedSong.notes[0]) == 3,
                   "Asynchronous generation overwrote a manual fingering correction")
        let restored = makeSession("annotations")
        restored.install(annotatedSong, storageKey: "regression")
        try expect(restored.showFingering && restored.hand(for: annotatedSong.notes[1]) == .left
                   && restored.finger(for: annotatedSong.notes[0]) == 3,
                   "Per-song hand/finger annotations failed to restore")
        restored.showFingering = false
        try expect(restored.finger(for: annotatedSong.notes[0]) == nil, "The fingering toggle did not hide labels")
        print("PASS: hand overrides, generated/manual fingering and per-song persistence")

        let displayed = makeSession("display-settings")
        displayed.setPracticeMode(.automatic)
        var display = PianoDisplaySettings()
        display.noteOpacity = 0.2
        display.highlightOpacity = 0.12
        display.feedbackOpacity = 0.4
        display.templateOpacity = 0.11
        display.noteGapMillimeters = 7
        display.rearOffsetMeters = 0.08
        display.surfaceHeightMeters = 0.025
        display.showsOnsetMarkers = false
        displayed.displaySettings = display
        let restoredDisplay = makeSession("display-settings")
        try expect(restoredDisplay.displaySettings == display && restoredDisplay.practiceMode == .automatic,
                   "Display preferences failed to persist independently of existing practice preferences")
        print("PASS: display opacity, gap and placement settings persist without losing practice mode")

        let received = makeSession("mac-import")
        let midiData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        guard let receiveFile = received.bridge.onMIDIFile else { throw RegressionFailure.assertion("Mac file callback missing") }
        let importedFile = LinkMIDIFile(title: "Mac\n练习曲", data: midiData)
        try await receiveFile(importedFile)
        try expect(received.library.count == 1 && received.song?.notes.isEmpty == false
                   && received.song?.title == importedFile.title && !received.isPlaying && !received.isImporting,
                   "A Mac MIDI transfer was not parsed, saved and installed before returning")
        let reloadedFile = makeSession("mac-import")
        try expect(reloadedFile.library.count == 1, "The received song was not committed to the library")
        reloadedFile.load(reloadedFile.library[0])
        try expect(reloadedFile.song?.notes.count == received.song?.notes.count,
                   "The received MIDI file did not survive a new session")
        print("PASS: Mac MIDI callback parses, durably saves and loads the received song")

        let legacyRoot = root.appending(path: "legacy-library")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacyID = UUID()
        let legacyIndex: [[String: Any]] = [["id": legacyID.uuidString, "title": "Legacy library song", "fileName": "legacy.mid",
                                           "noteCount": received.song!.notes.count, "duration": received.song!.duration]]
        try JSONSerialization.data(withJSONObject: legacyIndex).write(to: legacyRoot.appending(path: "library.json"), options: .atomic)
        try midiData.write(to: legacyRoot.appending(path: "legacy.mid"), options: .atomic)
        let legacyLibrary = makeSession("legacy-library")
        let legacyValues = try legacyRoot.appending(path: "legacy.mid")
            .resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        try expect(legacyLibrary.library.count == 1 && legacyLibrary.library[0].id == legacyID
                   && legacyLibrary.library[0].importID == nil && !legacyLibrary.library[0].isFavorite
                   && legacyLibrary.library[0].lastPlayedAt == nil
                   && legacyLibrary.library[0].importedAt == (legacyValues.creationDate ?? legacyValues.contentModificationDate),
                   "A legacy library index lost compatibility or failed to recover its saved MIDI date")
        try expect(legacyLibrary.load(legacyLibrary.library[0]), "A valid legacy library song failed to report successful loading")
        try expect(legacyLibrary.song?.title == "Legacy library song" && legacyLibrary.song?.notes.isEmpty == false,
                   "A legacy library entry could no longer load its MIDI file")
        try expect(legacyLibrary.currentLibraryEntryID == legacyID && legacyLibrary.library[0].lastPlayedAt != nil,
                   "Opening a legacy song failed to record its identity and recent-open time")
        print("PASS: legacy library JSON restores favorite defaults, MIDI dates and successful recent-open history")

        let sortingRoot = root.appending(path: "library-sorting")
        try FileManager.default.createDirectory(at: sortingRoot, withIntermediateDirectories: true)
        let sortingIDs = (0..<7).map { _ in UUID() }
        let sortingTitles = ["Étude 2", "Étude 10", "Étude 2", "Favorite 10", "Favorite 2", "Missing date", "Missing date again"]
        let importDates: [Double?] = [10, 20, 10, 5, 30, nil, nil]
        let recentDates: [Double?] = [20, 10, nil, 5, nil, nil, nil]
        let sortingEntries = sortingIDs.indices.map { index in
            LibraryEntry(id: sortingIDs[index], title: sortingTitles[index], fileName: "song-\(index).mid",
                         noteCount: 1, duration: 1, isFavorite: index == 3 || index == 4,
                         importedAt: importDates[index].map { Date(timeIntervalSince1970: $0) },
                         lastPlayedAt: recentDates[index].map { Date(timeIntervalSince1970: $0) })
        }
        try JSONEncoder().encode(sortingEntries).write(to: sortingRoot.appending(path: "library.json"), options: .atomic)
        let sorting = makeSession("library-sorting")
        let expectedSorts: [(LibrarySortOrder, [Int])] = [
            (.importedNewest, [4, 3, 1, 0, 2, 5, 6]),
            (.importedOldest, [3, 4, 0, 2, 1, 5, 6]),
            (.nameAscending, [4, 3, 0, 2, 1, 5, 6]),
            (.nameDescending, [3, 4, 6, 5, 1, 0, 2]),
            (.lastPlayed, [3, 4, 0, 1, 2, 5, 6])
        ]
        for (order, expected) in expectedSorts {
            sorting.librarySortOrder = order
            try expect(sorting.libraryEntries(matching: "", favoritesOnly: false).map(\.id) == expected.map { sortingIDs[$0] },
                       "Library \(order.rawValue) sorting lost favorite priority, natural order, date placement or stable ties")
        }
        sorting.librarySortOrder = .nameAscending
        try expect(sorting.libraryEntries(matching: "  ETUDE \n", favoritesOnly: false).map(\.id) == [0, 2, 1].map { sortingIDs[$0] }
                   && sorting.libraryEntries(matching: "", favoritesOnly: true).map(\.id) == [4, 3].map { sortingIDs[$0] }
                   && sorting.libraryEntries(matching: "favorite 2", favoritesOnly: true).map(\.id) == [sortingIDs[4]]
                   && sorting.libraryEntries(matching: "etude", favoritesOnly: true).isEmpty,
                   "Library search failed to trim whitespace, ignore case/accents, or intersect the favorites filter")
        try expect(sorting.library.map(\.id) == sortingIDs,
                   "Sorting or filtering changed the persisted library's base order")
        print("PASS: all library sorts keep favorites first, natural names, stable ties and undated entries last")

        let libraryPracticeSong = PianoSong(title: "Keep practicing while browsing", notes: [
            PianoNote(id: 0, pitch: 60, start: 0, duration: 1),
            PianoNote(id: 1, pitch: 64, start: 0, duration: 1)
        ], tracks: [SongTrack(id: 0, name: "Piano")])
        sorting.install(libraryPracticeSong, storageKey: "unlisted-practice")
        sorting.play()
        send([0x90, 60, 100], to: sorting)
        let browsingRevision = sorting.songRevision
        sorting.toggleFavorite(sorting.library[0])
        _ = sorting.libraryEntries(matching: "ETUDE", favoritesOnly: true)
        sorting.librarySortOrder = .nameDescending
        try expect(sorting.song == libraryPracticeSong && sorting.songRevision == browsingRevision
                   && sorting.isPlaying && sorting.isWaiting && sorting.activeNotes == [60]
                   && sorting.matchedWaitingPitches == [60] && sorting.hitCount == 0 && sorting.currentLibraryEntryID == nil,
                   "Searching, sorting or favoriting interrupted active practice or selected a library entry")
        let sortingRestored = makeSession("library-sorting")
        try expect(sortingRestored.librarySortOrder == .nameDescending && sortingRestored.library[0].isFavorite
                   && sortingRestored.library[0].importedAt == sortingEntries[0].importedAt
                   && sortingRestored.library[0].lastPlayedAt == sortingEntries[0].lastPlayedAt
                   && sortingRestored.library.map(\.id) == sortingIDs,
                   "Favorite metadata or the independent library sort preference failed to survive restart")
        try expect(sortingRestored.libraryEntries(matching: "  etude \n", favoritesOnly: true).map(\.id) == [sortingIDs[0]],
                   "A restored favorite could not be found with accent-insensitive search")
        print("PASS: search and favorites preserve live practice, and favorites plus sort preference survive restart")

        try midiData.write(to: sortingRoot.appending(path: sortingEntries[0].fileName), options: .atomic)
        let beforeManualOpen = Date()
        try expect(sortingRestored.load(sortingRestored.library[0]) && sortingRestored.currentLibraryEntryID == sortingIDs[0],
                   "Manually opening a valid library song failed to select its exact identity")
        let openedAt = sortingRestored.library[0].lastPlayedAt
        try expect(openedAt != nil && openedAt! >= beforeManualOpen && openedAt! <= Date()
                   && sortingRestored.library[0].importedAt == sortingEntries[0].importedAt && sortingRestored.library[0].isFavorite,
                   "Manual open did not use wall-clock time or overwrote import/favorite metadata")
        let historyRestored = makeSession("library-sorting")
        historyRestored.librarySortOrder = .lastPlayed
        try expect(historyRestored.library[0].lastPlayedAt == openedAt
                   && historyRestored.libraryEntries(matching: "", favoritesOnly: false).first?.id == sortingIDs[0],
                   "Recent-open history failed to survive restart or move the newly opened favorite to the front")
        print("PASS: successful manual opens preserve other metadata and persist wall-clock recent-open sorting")

        let favoriteFailureRoot = root.appending(path: "favorite-write-failure")
        let favoriteFailure = makeSession("favorite-write-failure")
        try await favoriteFailure.importMIDIFile(LinkMIDIFile(title: "Keep favorite atomic", data: midiData, activateOnImport: false))
        let beforeFavoriteFailure = favoriteFailure.library[0]
        favoriteFailure.install(libraryPracticeSong)
        favoriteFailure.play()
        send([0x90, 60, 100], to: favoriteFailure)
        try FileManager.default.removeItem(at: favoriteFailureRoot.appending(path: "library.json"))
        try FileManager.default.createDirectory(at: favoriteFailureRoot.appending(path: "library.json"), withIntermediateDirectories: true)
        favoriteFailure.toggleFavorite(beforeFavoriteFailure)
        try expect(!favoriteFailure.library[0].isFavorite && favoriteFailure.library[0].importedAt == beforeFavoriteFailure.importedAt
                   && favoriteFailure.library[0].lastPlayedAt == nil && favoriteFailure.errorMessage?.contains("收藏保存失败") == true
                   && favoriteFailure.song == libraryPracticeSong && favoriteFailure.isPlaying
                   && favoriteFailure.activeNotes == [60] && favoriteFailure.matchedWaitingPitches == [60],
                   "A failed atomic favorite write changed memory, dates, or active practice")
        try expect(favoriteFailure.load(beforeFavoriteFailure) && favoriteFailure.currentLibraryEntryID == beforeFavoriteFailure.id
                   && favoriteFailure.library[0].lastPlayedAt == nil
                   && favoriteFailure.errorMessage?.contains("最近打开时间保存失败") == true,
                   "A loaded song with a failed history save did not report loaded state and explicit metadata failure")
        let loadedFailureRevision = favoriteFailure.songRevision
        try FileManager.default.removeItem(at: favoriteFailureRoot.appending(path: beforeFavoriteFailure.fileName))
        try expect(!favoriteFailure.load(beforeFavoriteFailure) && favoriteFailure.songRevision == loadedFailureRevision
                   && favoriteFailure.currentLibraryEntryID == beforeFavoriteFailure.id && favoriteFailure.library[0].lastPlayedAt == nil,
                   "A failed MIDI load replaced the current song or advanced its recent-open metadata")
        print("PASS: failed favorite commits preserve memory; load reports parser and history-save outcomes honestly")

        var batchHost = 400.0
        let batch = PianoSession(libraryDirectory: root.appending(path: "batch-library"), loadsDemo: false, now: { batchHost })
        let currentSong = PianoSong(title: "Current practice", notes: [
            PianoNote(id: 0, pitch: 60, start: 0, duration: 1),
            PianoNote(id: 1, pitch: 64, start: 0, duration: 1),
            PianoNote(id: 2, pitch: 67, start: 2, duration: 1)
        ], tracks: [SongTrack(id: 0, name: "Piano")])
        batch.install(currentSong, storageKey: "current-practice")
        batch.setHand(.left, forTrack: 0)
        batch.setRate(0.5)
        batch.targetAlignmentMilliseconds = 1200
        batch.play()
        batch.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: batchHost))
        batch.receive(.init(kind: .noteOn, note: 62, velocity: 100, timestamp: batchHost))
        batch.receive(.init(kind: .noteOff, note: 62, timestamp: batchHost))
        let originalRevision = batch.songRevision
        let batchIDs = [UUID(), UUID()]
        guard let receiveBatch = batch.bridge.onMIDIFile else { throw RegressionFailure.assertion("Batch callback missing") }
        for (index, importID) in batchIDs.enumerated() {
            try await receiveBatch(LinkMIDIFile(title: "Batch \(index + 1)", data: midiData,
                                               activateOnImport: false, importID: importID))
            try expect(batch.song == currentSong && batch.songRevision == originalRevision
                       && batch.isPlaying && batch.isWaiting && batch.songTime == 0
                       && batch.waitingPitches == [60, 64] && batch.matchedWaitingPitches == [60]
                       && batch.activeNotes == [60] && batch.hitCount == 0 && batch.wrongCount == 1
                       && batch.missedCount == 0 && batch.playbackRate == 0.5 && batch.targetAlignmentMilliseconds == 1200
                       && batch.hand(for: currentSong.notes[0]) == .left && batch.enabledTrackIDs == [0]
                       && batch.library.count == index + 1 && !batch.isImporting,
                       "A library-only batch import changed the current song, clock, physical input, or practice state")
        }
        let firstBatchEntry = batch.library.first { $0.importID == batchIDs[0] }!
        try expect(batch.library.allSatisfy { $0.importedAt != nil && $0.lastPlayedAt == nil && !$0.isFavorite },
                   "A new batch import failed to date its arrival or incorrectly marked a song recently opened")
        batch.toggleFavorite(firstBatchEntry)
        let storedBatchData = try Data(contentsOf: root.appending(path: "batch-library").appending(path: firstBatchEntry.fileName))
        try expect(storedBatchData == midiData,
                   "A batch import returned before saving its MIDI bytes")
        print("PASS: batch library-only imports preserve active song, partial chord, scoring and practice settings")

        try await receiveBatch(LinkMIDIFile(title: "Retry after missing receipt", data: midiData,
                                           activateOnImport: false, importID: batchIDs[0]))
        try expect(batch.library.count == 2 && batch.library.contains { $0.id == firstBatchEntry.id }
                   && batch.library.first(where: { $0.id == firstBatchEntry.id })?.isFavorite == true
                   && batch.library.first(where: { $0.id == firstBatchEntry.id })?.importedAt == firstBatchEntry.importedAt
                   && batch.library.first(where: { $0.id == firstBatchEntry.id })?.lastPlayedAt == nil
                   && batch.song == currentSong && batch.isPlaying && batch.matchedWaitingPitches == [60],
                   "A retried queue item duplicated its saved entry or interrupted practice")
        let batchFileURL = root.appending(path: "batch-library").appending(path: firstBatchEntry.fileName)
        try FileManager.default.removeItem(at: batchFileURL)
        try await receiveBatch(LinkMIDIFile(title: "Repair missing file", data: midiData,
                                           activateOnImport: false, importID: batchIDs[0]))
        let repairedBatchData = try Data(contentsOf: batchFileURL)
        try expect(repairedBatchData == midiData && batch.library.count == 2
                   && batch.library.contains { $0.id == firstBatchEntry.id }
                   && batch.song == currentSong && batch.isPlaying && batch.matchedWaitingPitches == [60],
                   "A retry failed to repair the missing MIDI file in place while preserving current practice")
        let batchReloaded = makeSession("batch-library")
        try expect(batchReloaded.library.count == 2 && Set(batchReloaded.library.compactMap(\.importID)) == Set(batchIDs),
                   "Stable import identities did not survive a new session")
        try expect(batchReloaded.library.first(where: { $0.id == firstBatchEntry.id })?.isFavorite == true
                   && batchReloaded.library.first(where: { $0.id == firstBatchEntry.id })?.importedAt == firstBatchEntry.importedAt
                   && batchReloaded.library.allSatisfy { $0.lastPlayedAt == nil },
                   "Import retry or file repair lost favorite/import metadata or created recent-open history")
        try await batchReloaded.importMIDIFile(LinkMIDIFile(title: "Retry after restart", data: midiData,
                                                          activateOnImport: false, importID: batchIDs[0]))
        try expect(batchReloaded.library.count == 2 && batchReloaded.song == nil,
                   "Retry after receiver restart duplicated a queue item or activated a library-only song")
        try FileManager.default.removeItem(at: batchFileURL)
        try await batchReloaded.importMIDIFile(LinkMIDIFile(title: "Repair after restart", data: midiData,
                                                          activateOnImport: false, importID: batchIDs[0]))
        let restartedRepairData = try Data(contentsOf: batchFileURL)
        try expect(restartedRepairData == midiData && batchReloaded.library.count == 2
                   && batchReloaded.song == nil,
                   "A retry after receiver restart acknowledged a missing file without restoring it")
        try await batchReloaded.importMIDIFile(LinkMIDIFile(title: "Activate existing", data: midiData,
                                                          importID: batchIDs[0]))
        try expect(batchReloaded.library.count == 2 && batchReloaded.song?.title == firstBatchEntry.title,
                   "Active retry did not load the existing saved entry")
        try await batchReloaded.importMIDIFile(LinkMIDIFile(title: "Distinct queue item", data: midiData,
                                                          activateOnImport: false, importID: UUID()))
        try expect(batchReloaded.library.count == 3 && batchReloaded.song?.title == firstBatchEntry.title,
                   "Different queue items were incorrectly deduplicated by file contents")
        try expect(batchReloaded.library.allSatisfy { $0.lastPlayedAt == nil },
                   "Import activation incorrectly counted an automatic selection as a manual library open")
        let retainedEntry = batchReloaded.library.first { $0.id == firstBatchEntry.id }!
        try expect(batchReloaded.load(retainedEntry), "The imported entry could not be manually opened")
        let retainedOpenDate = batchReloaded.library.first { $0.id == firstBatchEntry.id }!.lastPlayedAt
        let retainedRevision = batchReloaded.songRevision
        try await batchReloaded.importMIDIFile(LinkMIDIFile(title: "Retry favorite after manual open", data: midiData,
                                                          activateOnImport: false, importID: batchIDs[0]))
        let retriedMetadata = batchReloaded.library.first { $0.id == firstBatchEntry.id }!
        let finalBatchRestore = makeSession("batch-library")
        try expect(retriedMetadata.isFavorite && retriedMetadata.importedAt == firstBatchEntry.importedAt
                   && retriedMetadata.lastPlayedAt == retainedOpenDate && retainedOpenDate != nil
                   && batchReloaded.songRevision == retainedRevision && batchReloaded.library.count == 3
                   && finalBatchRestore.library.first(where: { $0.id == firstBatchEntry.id })?.lastPlayedAt == retainedOpenDate,
                   "An importID retry overwrote a favorite, import date, manual-open history, or current song")
        print("PASS: stable queue import IDs prevent duplicates across retries and receiver restarts")

        batch.setPracticeMode(.automatic)
        batch.seek(to: 0.25)
        batch.play()
        batchHost += 3.5
        batch.receive(.init(kind: .noteOn, note: 65, velocity: 100, timestamp: batchHost))
        let automaticTime = batch.songTime
        let automaticWrongCount = batch.wrongCount
        try await receiveBatch(LinkMIDIFile(title: "Automatic practice import", data: midiData, activateOnImport: false))
        try expect(batch.song == currentSong && batch.songRevision == originalRevision && batch.isPlaying
                   && batch.practiceMode == .automatic && batch.songTime == automaticTime
                   && batch.wrongCount == automaticWrongCount && batch.activeNotes == [65],
                   "Library-only import paused or reset automatic practice")
        let emptyBatch = makeSession("empty-batch-library")
        try await emptyBatch.importMIDIFile(LinkMIDIFile(title: "Select later", data: midiData, activateOnImport: false))
        try expect(emptyBatch.library.count == 1 && emptyBatch.song == nil && !emptyBatch.isPlaying,
                   "A batch import activated a song in an empty receiver")
        print("PASS: library-only imports preserve automatic playback and never auto-select into an empty session")

        do {
            try await receiveFile(LinkMIDIFile(title: "Invalid", data: Data("not MIDI".utf8)))
            throw RegressionFailure.assertion("Invalid transferred MIDI was accepted")
        } catch is RegressionFailure { throw RegressionFailure.assertion("Invalid transferred MIDI was accepted") }
        catch { }
        try expect(received.library.count == 1 && received.song?.title == importedFile.title && !received.isImporting,
                   "A rejected MIDI transfer corrupted the current library or left importing stuck")
        print("PASS: malformed Mac MIDI is rejected without replacing the current song")

        let blockedRoot = root.appending(path: "blocked-library")
        try FileManager.default.createDirectory(at: blockedRoot.appending(path: "library.json"), withIntermediateDirectories: true)
        let blocked = PianoSession(libraryDirectory: blockedRoot, loadsDemo: false)
        do {
            try await blocked.importMIDIFile(LinkMIDIFile(title: "Cannot save", data: midiData))
            throw RegressionFailure.assertion("A failed library commit reported successful import")
        } catch is RegressionFailure { throw RegressionFailure.assertion("A failed library commit reported successful import") }
        catch { }
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: blockedRoot.path)
        try expect(blocked.library.isEmpty && blocked.song == nil && !remainingFiles.contains(where: { $0.hasSuffix(".mid") }),
                   "A failed library commit leaked the new file or installed an unsaved song")
        print("PASS: failed Mac import rolls back its file and does not report success")

        let cancelled = makeSession("cancelled-import")
        let importTask = Task { @MainActor in
            try await cancelled.importMIDIFile(LinkMIDIFile(title: "Cancelled", data: midiData))
        }
        importTask.cancel()
        do { try await importTask.value; throw RegressionFailure.assertion("Cancelled transfer installed a song") }
        catch is CancellationError { }
        try expect(cancelled.library.isEmpty && cancelled.song == nil && !cancelled.isImporting,
                   "Cancelled Mac import committed a stale song")
        print("PASS: cancelled Mac transfer cannot install a stale song")

        let cancelledInvalid = makeSession("cancelled-invalid-import")
        let invalidTask = Task { @MainActor in
            try await cancelledInvalid.importMIDIFile(LinkMIDIFile(title: "Old invalid file", data: Data("bad MIDI".utf8)))
        }
        invalidTask.cancel()
        do { try await invalidTask.value; throw RegressionFailure.assertion("Cancelled invalid transfer was accepted") }
        catch is CancellationError { }
        try expect(cancelledInvalid.errorMessage == nil && cancelledInvalid.library.isEmpty && !cancelledInvalid.isImporting,
                   "A cancelled parse overwrote the current session with a stale error")
        print("PASS: cancellation suppresses stale parse failures from an old Mac transfer")

        var relaxedHost = 1_000.0
        let relaxed = PianoSession(libraryDirectory: root.appending(path: "relaxed-hands"), loadsDemo: false, now: { relaxedHost })
        relaxed.install(PianoSong(title: "Humanized two hands", notes: [
            .init(id: 0, pitch: 48, start: 1, duration: 0.8),
            .init(id: 1, pitch: 60, start: 1.01, duration: 0.8),
            .init(id: 2, pitch: 64, start: 1.02, duration: 0.8),
            .init(id: 3, pitch: 48, start: 2, duration: 1),
            .init(id: 4, pitch: 60, start: 2, duration: 1),
            .init(id: 5, pitch: 64, start: 2, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano")]))
        relaxed.play()
        relaxedHost = 1_000.35
        relaxed.receive(.init(kind: .noteOn, note: 48, velocity: 100, timestamp: relaxedHost))
        relaxedHost = 1_001.5
        relaxed.updatePractice()
        try expect(relaxed.heldCorrectNotes == [48] && relaxed.matchedWaitingPitches == [48] && relaxed.hitCount == 0,
                   "An early left hand expired while still physically held")
        relaxed.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: relaxedHost))
        relaxedHost += 0.06
        relaxed.receive(.init(kind: .noteOn, note: 64, velocity: 100, timestamp: relaxedHost))
        try expect(relaxed.hitCount == 3 && relaxed.wrongCount == 0,
                   "Humanized score chord or hands more than one second apart failed to complete")
        relaxedHost += 1.3
        relaxed.updatePractice()
        try expect(relaxed.heldCorrectNotes == [48, 60, 64] && relaxed.correctNotes.isEmpty && relaxed.hitCount == 3,
                   "Long held feedback expired or a held note auto-passed the next repetition")
        relaxed.receive(.init(kind: .controlChange, controller: 64, value: 127, timestamp: relaxedHost))
        for pitch in [48, 60, 64] { relaxed.receive(.init(kind: .noteOff, note: pitch, timestamp: relaxedHost)) }
        try expect(relaxed.activeNotes.isEmpty && relaxed.heldCorrectNotes.isEmpty && relaxed.pedalDown,
                   "Sustain was incorrectly displayed as a physically held key")
        relaxedHost += 0.01
        for pitch in [48, 60, 64] { relaxed.receive(.init(kind: .noteOn, note: pitch, velocity: 100, timestamp: relaxedHost)) }
        try expect(relaxed.hitCount == 6, "Release/restrike failed to pass the repeated chord")
        print("PASS: default relaxed mode accepts early staggered hands, holds full-key feedback and requires repeated strikes")

        var feedbackHost = 2_000.0
        let feedbackSession = PianoSession(libraryDirectory: root.appending(path: "held-feedback"), loadsDemo: false, now: { feedbackHost })
        feedbackSession.install(PianoSong(title: "Feedback", notes: [.init(id: 0, pitch: 60, start: 0, duration: 4)], tracks: [.init(id: 0, name: "Piano")]))
        feedbackSession.play()
        feedbackSession.receive(.init(kind: .noteOn, note: 61, velocity: 100, timestamp: feedbackHost))
        feedbackHost += 1.2
        feedbackSession.updatePractice()
        try expect(feedbackSession.heldWrongNotes == [61] && feedbackSession.wrongNotes.isEmpty,
                   "Wrong held feedback expired after its short pulse")
        feedbackSession.receive(.init(kind: .noteOff, note: 61, timestamp: feedbackHost))
        try expect(feedbackSession.heldWrongNotes.isEmpty, "Released wrong key remained physically highlighted")
        feedbackSession.receive(.init(kind: .noteOn, note: 60, velocity: 100, channel: 0, timestamp: feedbackHost))
        feedbackSession.receive(.init(kind: .noteOn, note: 60, velocity: 100, channel: 1, timestamp: feedbackHost))
        feedbackSession.receive(.init(kind: .noteOff, note: 60, channel: 0, timestamp: feedbackHost))
        try expect(feedbackSession.heldCorrectNotes == [60] && feedbackSession.activeNotes == [60],
                   "One channel releasing cleared a pitch still held on another channel")
        feedbackSession.receive(.init(kind: .noteOn, note: 60, velocity: 0, channel: 1, timestamp: feedbackHost))
        try expect(feedbackSession.heldCorrectNotes.isEmpty && feedbackSession.activeNotes.isEmpty,
                   "Zero-velocity last-channel release failed to clear full-key feedback")
        print("PASS: held correctness survives short pulses, respects channels and clears on physical release")

        var crossingHost = 3_000.0
        let crossing = PianoSession(libraryDirectory: root.appending(path: "crossing-hands"), loadsDemo: false, now: { crossingHost })
        crossing.install(PianoSong(title: "Early left hand crosses a previous chord", notes: [
            .init(id: 0, pitch: 60, start: 1, duration: 0.1),
            .init(id: 1, pitch: 64, start: 1, duration: 0.1),
            .init(id: 2, pitch: 48, start: 1.2, duration: 0.3),
            .init(id: 3, pitch: 67, start: 1.3, duration: 0.3)
        ], tracks: [.init(id: 0, name: "Piano")]))
        crossing.play()
        for (time, pitch) in [(3_000.9, 60), (3_000.95, 48), (3_001.0, 67), (3_001.1, 64)] {
            crossingHost = time
            crossing.receive(.init(kind: .noteOn, note: pitch, velocity: 100, timestamp: time))
        }
        crossingHost = 3_001.5
        crossing.updatePractice()
        crossing.updatePractice()
        try expect(crossing.hitCount == 4 && crossing.wrongCount == 0 && crossing.heldCorrectNotes == [48, 60, 64, 67],
                   "Early future keys were lost while the previous hand/chord was still incomplete")
        print("PASS: early left-hand notes survive the preceding incomplete chord and subsequent gates")

        var skewHost = 3_500.0
        let skewSession = PianoSession(libraryDirectory: root.appending(path: "clock-skew-gates"), loadsDemo: false, now: { skewHost })
        skewSession.install(PianoSong(title: "Clock offset refresh", notes: [
            .init(id: 0, pitch: 60, start: 0, duration: 0.1),
            .init(id: 1, pitch: 64, start: 0.1, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano")]))
        skewSession.play()
        skewHost = 3_501.05
        skewSession.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: 3_501.05))
        skewHost = 3_501.10
        skewSession.receive(.init(kind: .noteOn, note: 64, velocity: 100, timestamp: 3_501.04))
        skewHost = 3_501.30
        skewSession.updatePractice()
        try expect(skewSession.hitCount == 2 && skewSession.wrongCount == 0 && skewSession.heldCorrectNotes == [60, 64],
                   "Clock synchronization moved a valid new source onset behind a consumed gate and lost it")
        print("PASS: clock-offset regression across adjacent gates does not swallow a fresh physical key")

        var resetHost = 4_000.0
        let feedbackReset = PianoSession(libraryDirectory: root.appending(path: "feedback-reset"), loadsDemo: false, now: { resetHost })
        let resetSong = PianoSong(title: "Partial chord resets", notes: [
            .init(id: 0, pitch: 60, start: 0, duration: 4),
            .init(id: 1, pitch: 64, start: 0, duration: 4)
        ], tracks: [.init(id: 0, name: "Piano")])
        for action in 0..<4 {
            feedbackReset.install(resetSong)
            feedbackReset.play()
            feedbackReset.receive(.init(kind: .noteOn, note: 60, velocity: 100, channel: 1, timestamp: resetHost))
            try expect(feedbackReset.heldCorrectNotes == [60], "Partial chord was not shown ready")
            switch action {
            case 0: feedbackReset.pause(); feedbackReset.play()
            case 1: feedbackReset.setRate(0.75)
            case 2: feedbackReset.targetAlignmentMilliseconds = 1200
            default: feedbackReset.receive(.init(kind: .controlChange, channel: 0, controller: 123, value: 0, timestamp: resetHost))
            }
            try expect(feedbackReset.activeNotes == [60] && feedbackReset.heldCorrectNotes.isEmpty,
                       "Discarded wait candidates falsely remained green after a clock/input reset")
            let resetPresentation = feedbackReset.notePresentation(for: resetSong.notes[0])
            try expect(resetPresentation.progress == .unplayed && !resetPresentation.isHeld && resetPresentation.needsRestrike,
                       "A discarded candidate retained score-note hold ownership or hid the required restrike")
            resetHost += 0.01
        }
        print("PASS: pause, rate, alignment-window and channel reset invalidate pending green feedback together")

        let legacySettingsRoot = root.appending(path: "legacy-tolerance-settings")
        try FileManager.default.createDirectory(at: legacySettingsRoot, withIntermediateDirectories: true)
        try Data(#"{"mode":"automatic","inputTolerance":"strict","chordWindowMilliseconds":50,"targetAlignmentMilliseconds":1500,"automaticHandSplit":false,"splitPitch":55,"showFingering":false}"#.utf8)
            .write(to: legacySettingsRoot.appending(path: "practice-settings.json"))
        try Data(#"{"noteOpacity":0.8,"highlightOpacity":0.32,"feedbackOpacity":0.62,"templateOpacity":0.18}"#.utf8)
            .write(to: legacySettingsRoot.appending(path: "display-settings.json"))
        var legacyHost = 4_500.0
        let migratedSettings = PianoSession(libraryDirectory: legacySettingsRoot, loadsDemo: false, now: { legacyHost })
        try expect(migratedSettings.practiceMode == .automatic && migratedSettings.targetAlignmentMilliseconds == 1500
                   && !migratedSettings.automaticHandSplit && migratedSettings.splitPitch == 55
                   && migratedSettings.displaySettings.feedbackOpacity == 1 && migratedSettings.displaySettings.showsKeyboardGuides,
                   "Ignoring removed strict settings lost the saved playback mode, alignment window or unrelated preferences")
        migratedSettings.install(PianoSong(title: "Legacy strict preference is ignored", notes: [
            .init(id: 0, pitch: 48, start: 1, duration: 2), .init(id: 1, pitch: 84, start: 1, duration: 2)
        ], tracks: [.init(id: 0, name: "Piano")]))
        migratedSettings.setPracticeMode(.waitForNotes)
        migratedSettings.play()
        legacyHost = 4_500.2
        migratedSettings.receive(.init(kind: .noteOn, note: 48, velocity: 100, timestamp: legacyHost))
        legacyHost = 4_500.21
        migratedSettings.receive(.init(kind: .noteOff, note: 48, timestamp: legacyHost))
        legacyHost = 4_501.8
        migratedSettings.receive(.init(kind: .noteOn, note: 84, velocity: 100, timestamp: legacyHost))
        try expect(migratedSettings.hitCount == 2 && migratedSettings.wrongCount == 0,
                   "A legacy strict/chord-window preference prevented a released, staggered chord from completing")
        let savedSettingsData = try Data(contentsOf: legacySettingsRoot.appending(path: "practice-settings.json"))
        let savedSettingsJSON = try JSONSerialization.jsonObject(with: savedSettingsData) as! [String: Any]
        try expect(savedSettingsJSON["inputTolerance"] == nil && savedSettingsJSON["chordWindowMilliseconds"] == nil,
                   "Saving current preferences wrote removed strict-mode settings again")
        let restoredCurrentSettings = makeSession("legacy-tolerance-settings")
        try expect(restoredCurrentSettings.practiceMode == .waitForNotes && restoredCurrentSettings.targetAlignmentMilliseconds == 1500
                   && !restoredCurrentSettings.automaticHandSplit && restoredCurrentSettings.splitPitch == 55,
                   "Preferences without the removed strict-mode fields failed to restore")
        print("PASS: legacy strict settings are ignored, removed keys are no longer saved, other preferences survive")

        var windowHost = 5_000.0
        let wideWindow = PianoSession(libraryDirectory: root.appending(path: "target-alignment-window"), loadsDemo: false, now: { windowHost })
        wideWindow.targetAlignmentMilliseconds = 2000
        wideWindow.install(PianoSong(title: "Two-second target alignment", notes: [
            .init(id: 0, pitch: 48, start: 2, duration: 1),
            .init(id: 1, pitch: 60, start: 2, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano")]))
        wideWindow.play()
        windowHost += 0.5
        wideWindow.receive(.init(kind: .noteOn, note: 48, velocity: 100, timestamp: windowHost))
        windowHost += 0.1
        wideWindow.receive(.init(kind: .noteOff, note: 48, timestamp: windowHost))
        windowHost = 5_002.0
        wideWindow.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: windowHost))
        try expect(wideWindow.hitCount == 2 && wideWindow.wrongCount == 0,
                   "Two-second target alignment did not permit an early released chord note")
        let timeBeforeAlignmentChange = wideWindow.songTime
        let wasPlayingBeforeAlignmentChange = wideWindow.isPlaying
        wideWindow.targetAlignmentMilliseconds = 50
        try expect(wideWindow.hitCount == 2 && wideWindow.songTime == timeBeforeAlignmentChange
                   && wideWindow.isPlaying == wasPlayingBeforeAlignmentChange,
                   "Changing target alignment discarded completed progress or moved the playback clock")
        let lowWindow = makeSession("target-alignment-window")
        try expect(lowWindow.targetAlignmentMilliseconds == 50, "50ms target alignment failed to persist")
        wideWindow.targetAlignmentMilliseconds = 2000
        let highWindow = makeSession("target-alignment-window")
        try expect(highWindow.targetAlignmentMilliseconds == 2000, "Two-second target alignment failed to persist")
        print("PASS: 50ms–2s target alignment persists and changes without resetting completed progress or playback")

        var automaticAlignmentHost = 5_500.0
        let automaticAlignment = PianoSession(libraryDirectory: root.appending(path: "automatic-target-alignment"),
                                               loadsDemo: false, now: { automaticAlignmentHost })
        automaticAlignment.targetAlignmentMilliseconds = 1500
        automaticAlignment.setPracticeMode(.automatic)
        automaticAlignment.install(PianoSong(title: "Automatic target alignment", notes: [
            .init(id: 0, pitch: 60, start: 2, duration: 1), .init(id: 1, pitch: 64, start: 2, duration: 1),
            .init(id: 2, pitch: 67, start: 4, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano")]))
        automaticAlignment.play()
        automaticAlignmentHost = 5_503.5
        automaticAlignment.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: automaticAlignmentHost))
        automaticAlignmentHost = 5_506.5
        automaticAlignment.receive(.init(kind: .noteOn, note: 64, velocity: 100, timestamp: automaticAlignmentHost))
        try expect(automaticAlignment.hitCount == 2, "Automatic scoring did not apply the saved target alignment in both directions")
        automaticAlignment.targetAlignmentMilliseconds = 50
        automaticAlignment.receive(.init(kind: .noteOn, note: 67, velocity: 100, timestamp: automaticAlignmentHost))
        try expect(automaticAlignment.hitCount == 2 && automaticAlignment.wrongCount == 1,
                   "Shrinking automatic target alignment reset scores or still accepted a 500ms-early note")
        automaticAlignment.targetAlignmentMilliseconds = 2000
        automaticAlignment.receive(.init(kind: .noteOff, note: 67, timestamp: automaticAlignmentHost))
        automaticAlignment.receive(.init(kind: .noteOn, note: 67, velocity: 100, timestamp: automaticAlignmentHost))
        try expect(automaticAlignment.hitCount == 3 && automaticAlignment.wrongCount == 1,
                   "Widening automatic target alignment lost history or failed to admit the remaining note")
        print("PASS: automatic target alignment changes acceptance in both directions while retaining scores")

        var rollHost = 6_000.0
        let rolledSession = PianoSession(libraryDirectory: root.appending(path: "rolled-chord-note-colors"), loadsDemo: false, now: { rollHost })
        let rolledSong = PianoSong(title: "Large span rolled chord", notes: [
            .init(id: 0, pitch: 36, start: 1, duration: 2),
            .init(id: 1, pitch: 36, start: 1, duration: 2, track: 1),
            .init(id: 2, pitch: 36, start: 1.01, duration: 2, track: 1, channel: 1),
            .init(id: 3, pitch: 60, start: 1, duration: 2),
            .init(id: 4, pitch: 84, start: 1, duration: 2),
            .init(id: 5, pitch: 36, start: 4, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano"), .init(id: 1, name: "Doubled staff")])
        func rolledNote(_ id: Int) -> PianoNote { rolledSong.notes.first { $0.id == id }! }
        rolledSession.install(rolledSong)
        rolledSession.play()
        rollHost += 0.9
        rolledSession.receive(.init(kind: .noteOn, note: 36, velocity: 100, timestamp: rollHost))
        rollHost += 0.01
        rolledSession.receive(.init(kind: .noteOff, note: 36, timestamp: rollHost))
        rollHost = 6_001.5
        rolledSession.updatePractice()
        try expect(rolledSession.matchedWaitingPitches == [36] && rolledSession.activeNotes.isEmpty
                   && rolledSession.heldCorrectNotes.isEmpty && rolledSession.hitCount == 0,
                   "Released rolled note lost progress, falsely held a key down, or scored a whole chord")
        for id in [0, 1, 2] {
            try expect(rolledSession.noteFeedback(for: rolledNote(id)) == .matched,
                       "A matched score alias failed to keep its exact note bar green after release")
        }
        for id in [3, 4, 5] {
            try expect(rolledSession.noteFeedback(for: rolledNote(id)) == .normal,
                       "One played pitch coloured unplayed chord tones or a future repeated note")
        }
        rollHost += 0.5
        rolledSession.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: rollHost))
        rolledSession.receive(.init(kind: .noteOff, note: 60, timestamp: rollHost))
        rollHost += 0.5
        rolledSession.receive(.init(kind: .noteOn, note: 84, velocity: 100, timestamp: rollHost))
        try expect(rolledSession.hitCount == 3 && rolledSession.wrongCount == 0,
                   "A large rolled chord failed to complete from separately released physical strikes")
        rolledSession.receive(.init(kind: .noteOff, note: 84, timestamp: rollHost))
        try expect((0...4).allSatisfy { rolledSession.noteFeedback(for: rolledNote($0)) == .matched }
                   && rolledSession.noteFeedback(for: rolledNote(5)) == .normal,
                   "Completed chord colors did not remain local to the consumed score notes")
        rolledSession.seek(to: 1)
        try expect(rolledSession.noteFeedback(for: rolledNote(0)) == .normal && rolledSession.matchedWaitingPitches.isEmpty,
                   "Seeking retained old rolled-chord progress or note-bar colors")
        print("PASS: large chords collect released strikes, exact aliases highlight, and future repetitions stay unplayed")

        var autoColorsHost = 7_100.0
        let automaticColors = PianoSession(libraryDirectory: root.appending(path: "automatic-note-colors"), loadsDemo: false, now: { autoColorsHost })
        automaticColors.setPracticeMode(.automatic)
        let automaticSong = PianoSong(title: "Exact repeated automatic bars", notes: [
            .init(id: 10, pitch: 60, start: 0, duration: 0.2),
            .init(id: 11, pitch: 60, start: 0, duration: 0.2, track: 1),
            .init(id: 12, pitch: 60, start: 2, duration: 0.2)
        ], tracks: [.init(id: 0, name: "Piano"), .init(id: 1, name: "Double")])
        automaticColors.install(automaticSong)
        automaticColors.play()
        autoColorsHost += 3
        automaticColors.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: autoColorsHost))
        for note in automaticSong.notes {
            try expect(automaticColors.noteFeedback(for: note) == (note.start == 0 ? .matched : .normal),
                       "Automatic note-bar color failed to share exact aliases or incorrectly lit a future repeated note")
        }
        automaticColors.install(automaticSong)
        try expect(automaticSong.notes.allSatisfy { automaticColors.noteFeedback(for: $0) == .normal },
                   "Replacing/restarting a score retained stale matched note-bar feedback")
        print("PASS: automatic feedback shares exact-onset aliases without lighting later repetitions or leaking across installs")

        var thickNotes = rolledSession.displaySettings
        thickNotes.noteThicknessMillimeters = 14
        rolledSession.displaySettings = thickNotes
        let restoredThickness = makeSession("rolled-chord-note-colors")
        try expect(restoredThickness.displaySettings.noteThicknessMillimeters == 14,
                   "Spatial note thickness setting did not persist through the real session")
        print("PASS: adjustable spatial note thickness persists through session reload")

        var targetHost = 7_000.0
        let targetSession = PianoSession(libraryDirectory: root.appending(path: "presentation-targets"), loadsDemo: false, now: { targetHost })
        targetSession.targetAlignmentMilliseconds = 800
        let targetSong = PianoSong(title: "Humanized target look-ahead", notes: [
            .init(id: 0, pitch: 48, start: 1, duration: 0.7),
            .init(id: 1, pitch: 60, start: 1.02, duration: 0.7),
            .init(id: 2, pitch: 67, start: 1.4, duration: 0.4),
            .init(id: 3, pitch: 72, start: 2.5, duration: 0.5)
        ], tracks: [.init(id: 0, name: "Piano")])
        targetSession.install(targetSong)
        try expect(!targetSession.isWaiting && targetSession.currentTargetNoteIDs == [0, 1]
                   && targetSession.currentTargetPitches == [48, 60] && targetSession.nextTargetNoteIDs == [2]
                   && targetSession.nextTargetPitches == [67] && targetSession.currentTargetTime == 1
                   && targetSession.nextTargetTime == 1.4,
                   "Current/next score groups were hidden before playback or split a humanized chord")
        try expect(targetSession.notePresentation(for: targetSong.notes[0]).role == .current
                   && targetSession.notePresentation(for: targetSong.notes[1]).role == .current
                   && targetSession.notePresentation(for: targetSong.notes[2]).role == .next
                   && targetSession.notePresentation(for: targetSong.notes[3]).role == .upcoming,
                   "Note roles did not use the gate's exact anchored groups")
        targetSession.play()
        targetHost += 0.2
        try expect(!targetSession.isWaiting && targetSession.targetPreviewNoteIDs == [0, 1]
                   && targetSession.targetPreviewPitches == [48, 60],
                   "A chord's later 30ms members did not preview together at its first onset's preparation boundary")
        targetHost += 0.7
        targetSession.receive(.init(kind: .noteOn, note: 48, velocity: 100, timestamp: targetHost))
        targetSession.receive(.init(kind: .noteOff, note: 48, timestamp: targetHost))
        targetSession.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: targetHost))
        targetHost = 7_001.0
        targetSession.updatePractice()
        try expect(targetSession.currentTargetNoteIDs == [2] && targetSession.nextTargetNoteIDs == [3]
                   && !targetSession.isWaiting && targetSession.hitCount == 2,
                   "Completing a chord hid the following groups until the next stop or delayed resumption")
        print("PASS: current/next groups and anchored chord previews remain available before stops and immediately after resume")

        for rate in [0.5, 2.0] {
            var previewHost = 8_000.0
            let previewSession = PianoSession(libraryDirectory: root.appending(path: "preview-rate-\(rate)"), loadsDemo: false, now: { previewHost })
            previewSession.targetAlignmentMilliseconds = 800
            previewSession.install(PianoSong(title: "Wall-clock preparation window", notes: [
                .init(id: 0, pitch: 60, start: 2, duration: 1),
                .init(id: 1, pitch: 64, start: 2.02, duration: 1)
            ], tracks: [.init(id: 0, name: "Piano")]))
            previewSession.setRate(rate)
            previewSession.play()
            previewHost += 2 / rate - 0.81
            try expect(previewSession.targetPreviewPitches.isEmpty,
                       "Keyboard preparation appeared earlier than the real-time alignment allowance at rate \(rate)")
            previewHost += 0.02
            try expect(previewSession.targetPreviewPitches == [60, 64],
                       "Keyboard preparation failed to scale score distance by playback rate \(rate)")
        }
        print("PASS: target keyboard preview uses the real-time alignment window at slow and fast playback rates")

        for rate in [0.5, 2.0] {
            var autoPreviewHost = 8_500.0
            let autoPreview = PianoSession(libraryDirectory: root.appending(path: "automatic-preview-rate-\(rate)"), loadsDemo: false, now: { autoPreviewHost })
            autoPreview.targetAlignmentMilliseconds = 800
            autoPreview.setPracticeMode(.automatic)
            autoPreview.install(PianoSong(title: "Score-time matcher preview", notes: [
                .init(id: 0, pitch: 60, start: 2, duration: 4),
                .init(id: 1, pitch: 64, start: 2, duration: 4)
            ], tracks: [.init(id: 0, name: "Piano")]))
            autoPreview.setRate(rate)
            autoPreview.play()
            autoPreviewHost += 3 + (2 - 0.81) / rate
            try expect(autoPreview.targetPreviewPitches.isEmpty,
                       "Automatic preview started outside its existing score-time matcher window at rate \(rate)")
            autoPreviewHost += 0.02 / rate
            try expect(autoPreview.targetPreviewPitches == [60, 64],
                       "Automatic preview used a host-time window that disagreed with its matcher at rate \(rate)")
            autoPreview.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: autoPreviewHost))
            try expect(autoPreview.hitCount == 1 && autoPreview.targetPreviewPitches == [64],
                       "Automatic preview and early scoring disagreed or kept a completed onset in the preparation cue")
            autoPreviewHost = 8_503 + 3 / rate
            try expect(autoPreview.targetPreviewPitches.isEmpty,
                       "A sustained long-note body kept asking for its onset after the late matcher window had passed")
        }
        print("PASS: automatic preview follows score-time scoring at non-1x rates and excludes completed or overdue long-note onsets")

        var pulseHost = 9_000.0
        let pulseSession = PianoSession(libraryDirectory: root.appending(path: "independent-input-echo"), loadsDemo: false, now: { pulseHost })
        let pulseSong = PianoSong(title: "Short partial chord", notes: [
            .init(id: 0, pitch: 60, start: 0, duration: 1), .init(id: 1, pitch: 64, start: 0, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano")])
        pulseSession.install(pulseSong)
        pulseSession.play()
        pulseSession.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: pulseHost))
        pulseSession.receive(.init(kind: .noteOff, note: 60, timestamp: pulseHost))
        let pulseNote = pulseSession.notePresentation(for: pulseSong.notes[0])
        try expect(pulseSession.hitCount == 0 && pulseSession.activeNotes.isEmpty && pulseSession.correctNotes.isEmpty
                   && pulseSession.inputPulsePitches == [60] && pulseSession.inputPulseIntensity(for: 60) == 1
                   && pulseNote.progress == .accepted && !pulseNote.isHeld && !pulseNote.isPendingEarly,
                   "Between-frame partial staccato had no physical echo or falsely remained held/scored")
        pulseHost += 0.1
        let fadingIntensity = pulseSession.inputPulseIntensity(for: 60)
        try expect(fadingIntensity > 0 && fadingIntensity < 1, "Input echo did not fade independently of chord completion")
        pulseHost += 0.1
        try expect(pulseSession.inputPulsePitches.isEmpty && pulseSession.inputPulseIntensity(for: 60) == 0
                   && pulseSession.notePresentation(for: pulseSong.notes[0]).progress == .accepted,
                   "Expiring raw feedback discarded a relaxed arpeggio's accepted progress")
        print("PASS: between-frame staccato produces an independent fading input echo while incomplete arpeggio progress persists")

        var ignoredHost = 9_500.0
        let ignoredSession = PianoSession(libraryDirectory: root.appending(path: "ignored-input-echo"), loadsDemo: false, now: { ignoredHost })
        ignoredSession.targetAlignmentMilliseconds = 800
        let ignoredSong = PianoSong(title: "Input without score ownership", notes: [
            .init(id: 0, pitch: 60, start: 2, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano")])
        ignoredSession.install(ignoredSong)
        for isPlaying in [false, true] {
            if isPlaying { ignoredSession.play() }
            ignoredSession.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: ignoredHost))
            let ignoredPresentation = ignoredSession.notePresentation(for: ignoredSong.notes[0])
            try expect(ignoredPresentation.progress == .unplayed && !ignoredPresentation.isHeld
                       && ignoredSession.noteFeedback(for: ignoredSong.notes[0]) == .normal
                       && ignoredSession.inputPulseIntensity(for: 60) == 1 && ignoredSession.hitCount == 0,
                       "Paused/too-early input either lacked a physical echo or falsely lit an unaccepted score bar")
            ignoredSession.receive(.init(kind: .noteOff, note: 60, timestamp: ignoredHost))
            ignoredHost += 0.01
        }
        ignoredSession.inputChannel = 0
        ignoredSession.receive(.init(kind: .noteOn, note: 67, velocity: 100, channel: 1, timestamp: ignoredHost))
        try expect(ignoredSession.inputPulseIntensity(for: 67) == 0, "An excluded MIDI channel produced visible input feedback")
        ignoredSession.resetInput()
        try expect(ignoredSession.inputPulsePitches.isEmpty && ignoredSession.activeNotes.isEmpty,
                   "Input reset left a stale raw echo or physical hold")
        print("PASS: paused/ignored input echoes immediately without claiming score ownership, and filtering/reset remain authoritative")

        var pendingHost = 10_000.0
        let pendingSession = PianoSession(libraryDirectory: root.appending(path: "presentation-pending"), loadsDemo: false, now: { pendingHost })
        pendingSession.targetAlignmentMilliseconds = 800
        let pendingSong = PianoSong(title: "Current latch and revocable future", notes: [
            .init(id: 0, pitch: 48, start: 1, duration: 2),
            .init(id: 1, pitch: 48, start: 1.01, duration: 2, track: 1),
            .init(id: 2, pitch: 60, start: 1, duration: 2),
            .init(id: 3, pitch: 67, start: 1.2, duration: 1),
            .init(id: 4, pitch: 48, start: 2, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano"), .init(id: 1, name: "Alias")])
        func pendingNote(_ id: Int) -> PianoNote { pendingSong.notes.first { $0.id == id }! }
        pendingSession.install(pendingSong)
        pendingSession.play()
        pendingHost += 0.9
        pendingSession.receive(.init(kind: .noteOn, note: 48, velocity: 100, timestamp: pendingHost))
        for id in [0, 1] {
            let presentation = pendingSession.notePresentation(for: pendingNote(id))
            try expect(presentation.role == .current && presentation.progress == .accepted
                       && presentation.isHeld && !presentation.isPendingEarly,
                       "Current hand aliases did not share exact accepted and physical-hold presentation")
        }
        try expect(pendingSession.targetPreviewPitches == [60, 67],
                   "A current accepted alias still asked for its already played key in the target preview")
        pendingHost += 0.01
        pendingSession.receive(.init(kind: .noteOn, note: 67, velocity: 100, timestamp: pendingHost))
        let pendingFuture = pendingSession.notePresentation(for: pendingNote(3))
        try expect(pendingFuture.role == .next && pendingFuture.progress == .accepted
                   && pendingFuture.isHeld && pendingFuture.isPendingEarly,
                   "Early future input was indistinguishable from a current accumulated arpeggio")
        try expect(pendingSession.targetPreviewPitches == [60],
                   "A held early future candidate was redundantly presented as a missing target")
        pendingSession.receive(.init(kind: .noteOff, note: 67, timestamp: pendingHost))
        try expect(pendingSession.notePresentation(for: pendingNote(3)).progress == .unplayed
                   && !pendingSession.notePresentation(for: pendingNote(3)).isHeld
                   && !pendingSession.heldCorrectNotes.contains(67),
                   "A released future candidate retained pending color or physical ownership")
        try expect(pendingSession.targetPreviewPitches == [60, 67],
                   "Cancelling an early future candidate failed to restore that missing key's preparation cue")
        pendingSession.receive(.init(kind: .noteOff, note: 48, timestamp: pendingHost))
        try expect(pendingSession.notePresentation(for: pendingNote(0)).progress == .accepted
                   && !pendingSession.notePresentation(for: pendingNote(0)).isHeld
                   && pendingSession.notePresentation(for: pendingNote(4)).progress == .unplayed
                   && !pendingSession.notePresentation(for: pendingNote(4)).isHeld,
                   "Current release lost accumulated progress or leaked hold/progress into a later repeated pitch")
        pendingHost = 10_001.1
        pendingSession.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: pendingHost))
        try expect(pendingSession.notePresentation(for: pendingNote(0)).progress == .completed
                   && pendingSession.currentTargetNoteIDs == [3],
                   "Current accepted progress failed to become completed on group advance")
        pendingSession.receive(.init(kind: .noteOn, note: 67, velocity: 100, timestamp: pendingHost))
        try expect(pendingSession.notePresentation(for: pendingNote(3)).progress == .accepted
                   && !pendingSession.notePresentation(for: pendingNote(3)).isPendingEarly
                   && pendingSession.notePresentation(for: pendingNote(3)).isHeld,
                   "Retrying a released future after promotion did not acquire its current target")
        pendingSession.pause()
        try expect(pendingSession.notePresentation(for: pendingNote(3)).progress == .unplayed
                   && !pendingSession.notePresentation(for: pendingNote(3)).isHeld
                   && pendingSession.notePresentation(for: pendingNote(3)).needsRestrike
                   && !pendingSession.heldCorrectNotes.contains(67),
                   "Pause left an early current candidate accepted/held instead of requiring a fresh onset")
        pendingSession.resetInput()
        try expect(!pendingSession.notePresentation(for: pendingNote(2)).isHeld && pendingSession.activeNotes.isEmpty,
                   "Global input reset retained a completed note's physical hold")
        print("PASS: current aliases accumulate separately from revocable future candidates, and pause/reset invalidate exact pending holds")

        var heldHost = 11_000.0
        let exactHeld = PianoSession(libraryDirectory: root.appending(path: "precise-held-repeat"), loadsDemo: false, now: { heldHost })
        let exactHeldSong = PianoSong(title: "Held repeat ownership", notes: [
            .init(id: 0, pitch: 60, start: 0, duration: 4),
            .init(id: 1, pitch: 60, start: 0, duration: 4, track: 1),
            .init(id: 2, pitch: 60, start: 1, duration: 3)
        ], tracks: [.init(id: 0, name: "Piano"), .init(id: 1, name: "Alias")])
        exactHeld.install(exactHeldSong)
        exactHeld.play()
        exactHeld.receive(.init(kind: .noteOn, note: 60, velocity: 100, channel: 0, timestamp: heldHost))
        exactHeld.receive(.init(kind: .noteOn, note: 60, velocity: 100, channel: 1, timestamp: heldHost))
        heldHost += 0.5
        for note in exactHeldSong.notes {
            let presentation = exactHeld.notePresentation(for: note)
            try expect(presentation.isHeld == (note.start == 0), "A long held onset leaked into an exact repeated score identity")
        }
        try expect(exactHeld.notePresentation(for: exactHeldSong.notes[2]).needsRestrike,
                   "The next repeated key failed to explain that the old physical hold needs release/restrike")
        exactHeld.receive(.init(kind: .noteOff, note: 60, channel: 0, timestamp: heldHost))
        try expect(exactHeld.notePresentation(for: exactHeldSong.notes[0]).isHeld,
                   "First-channel release cleared a long note still physically held on another channel")
        exactHeld.pause()
        try expect(exactHeld.notePresentation(for: exactHeldSong.notes[0]).isHeld,
                   "Pause removed a completed note's genuine physical hold")
        exactHeld.receive(.init(kind: .noteOn, note: 60, velocity: 0, channel: 1, timestamp: heldHost))
        try expect(exactHeldSong.notes.allSatisfy { !exactHeld.notePresentation(for: $0).isHeld },
                   "Final-channel zero-velocity release retained exact score hold ownership")
        exactHeld.play()
        heldHost += 0.1
        exactHeld.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: heldHost))
        try expect(!exactHeld.notePresentation(for: exactHeldSong.notes[0]).isHeld
                   && exactHeld.notePresentation(for: exactHeldSong.notes[2]).isHeld,
                   "A fresh repeated strike reactivated the previous long note's held indicator")
        exactHeld.seek(to: 0)
        try expect(exactHeldSong.notes.allSatisfy { !exactHeld.notePresentation(for: $0).isHeld }
                   && exactHeld.inputPulsePitches.isEmpty,
                   "Seeking retained old physical score ownership or a previous input echo")
        print("PASS: exact held-note aliases survive intermediate channel releases and completed pauses, while repeats and seeks stay isolated")

        var autoHeldHost = 12_000.0
        let autoHeld = PianoSession(libraryDirectory: root.appending(path: "automatic-held-identity"), loadsDemo: false, now: { autoHeldHost })
        autoHeld.setPracticeMode(.automatic)
        autoHeld.install(exactHeldSong)
        autoHeld.play()
        autoHeldHost += 3
        autoHeld.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: autoHeldHost))
        autoHeldHost += 1.05
        for note in exactHeldSong.notes {
            let presentation = autoHeld.notePresentation(for: note)
            try expect(presentation.isHeld == (note.start == 0)
                       && presentation.progress == (note.start == 0 ? .completed : .unplayed),
                       "Automatic sustained feedback failed to preserve exact aliases or leaked into an overlapping repetition")
        }
        autoHeld.receive(.init(kind: .noteOff, note: 60, timestamp: autoHeldHost))
        autoHeld.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: autoHeldHost))
        try expect(autoHeld.hitCount == 2 && exactHeldSong.notes.allSatisfy {
            autoHeld.notePresentation(for: $0).isHeld == ($0.start == 1)
        }, "Automatic repeated strike did not transfer physical ownership to the newly matched exact onset")
        autoHeld.setPracticeMode(.waitForNotes)
        try expect(autoHeld.activeNotes.isEmpty && exactHeldSong.notes.allSatisfy { !autoHeld.notePresentation(for: $0).isHeld },
                   "Changing practice modes retained automatic score hold identities")
        print("PASS: automatic long-note holds follow exact matched aliases through repeated onsets and clear on mode changes")

        var expiredHost = 13_000.0
        let expiredOnset = PianoSession(libraryDirectory: root.appending(path: "automatic-expired-restrike"), loadsDemo: false, now: { expiredHost })
        expiredOnset.targetAlignmentMilliseconds = 800
        let expiredSong = PianoSong(title: "Expired onset with a long body", notes: [
            .init(id: 0, pitch: 60, start: 0, duration: 8)
        ], tracks: [.init(id: 0, name: "Piano")])
        expiredOnset.setPracticeMode(.automatic)
        expiredOnset.install(expiredSong)
        expiredOnset.play()
        expiredHost += 6
        expiredOnset.updatePractice()
        expiredOnset.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: expiredHost))
        let expiredPresentation = expiredOnset.notePresentation(for: expiredSong.notes[0])
        try expect(expiredPresentation.role == .current && expiredPresentation.progress == .unplayed
                   && !expiredPresentation.isHeld && !expiredPresentation.needsRestrike
                   && expiredOnset.targetPreviewNoteIDs.isEmpty && expiredOnset.activeNotes == [60]
                   && expiredOnset.inputPulseIntensity(for: 60) == 1
                   && expiredOnset.hitCount == 0 && expiredOnset.missedCount == 1 && expiredOnset.wrongCount == 1,
                   "An expired long-note onset requested an impossible restrike or lost its independent physical input echo")
        print("PASS: expired automatic long-note onsets never request an unmatchable restrike while raw key input still echoes")

        var defaultHost = 14_000.0
        let newDefaults = PianoSession(libraryDirectory: root.appending(path: "new-user-defaults"), loadsDemo: false, now: { defaultHost })
        try expect(newDefaults.targetAlignmentMilliseconds == 2000
                   && newDefaults.displaySettings.noteOpacity == 1
                   && newDefaults.displaySettings.highlightOpacity == 1
                   && newDefaults.displaySettings.feedbackOpacity == 1
                   && newDefaults.displaySettings.templateOpacity == 0,
                   "A new session did not use the requested two-second alignment and opaque input/note defaults")
        newDefaults.install(PianoSong(title: "Default two-second input window", notes: [
            .init(id: 0, pitch: 60, start: 2, duration: 1), .init(id: 1, pitch: 64, start: 2, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano")]))
        newDefaults.play()
        defaultHost += 0.25
        newDefaults.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: defaultHost))
        newDefaults.receive(.init(kind: .noteOff, note: 60, timestamp: defaultHost))
        defaultHost = 14_002
        newDefaults.receive(.init(kind: .noteOn, note: 64, velocity: 100, timestamp: defaultHost))
        try expect(newDefaults.hitCount == 2 && newDefaults.wrongCount == 0,
                   "The new displayed alignment default was not applied to actual released early-chord input")
        print("PASS: new sessions use two-second alignment and opaque notes/feedback with the practice template hidden")

        let defaultsMigrationRoot = root.appending(path: "defaults-migration")
        try FileManager.default.createDirectory(at: defaultsMigrationRoot, withIntermediateDirectories: true)
        try Data(#"{"mode":"automatic","automaticHandSplit":false,"splitPitch":55,"showFingering":false,"targetAlignmentMilliseconds":800}"#.utf8)
            .write(to: defaultsMigrationRoot.appending(path: "practice-settings.json"))
        try Data(#"{"contrastVersion":1,"noteOpacity":0.92,"highlightOpacity":0.64,"feedbackOpacity":0.96,"templateOpacity":0.30,"noteGapMillimeters":7,"showsKeyboardGuides":false}"#.utf8)
            .write(to: defaultsMigrationRoot.appending(path: "display-settings.json"))
        let upgradedDefaults = makeSession("defaults-migration")
        try expect(upgradedDefaults.targetAlignmentMilliseconds == 2000 && upgradedDefaults.practiceMode == .automatic
                   && !upgradedDefaults.automaticHandSplit && upgradedDefaults.splitPitch == 55
                   && upgradedDefaults.displaySettings.noteOpacity == 1 && upgradedDefaults.displaySettings.highlightOpacity == 1
                   && upgradedDefaults.displaySettings.feedbackOpacity == 1 && upgradedDefaults.displaySettings.templateOpacity == 0
                   && upgradedDefaults.displaySettings.noteGapMillimeters == 7 && !upgradedDefaults.displaySettings.showsKeyboardGuides,
                   "Migrating old defaults lost unrelated choices or failed to upgrade the previous default values")
        for fileName in ["practice-settings.json", "display-settings.json"] {
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: defaultsMigrationRoot.appending(path: fileName))) as! [String: Any]
            let expectedVersion = fileName == "display-settings.json" ? PianoDisplaySettings.currentPreferenceVersion : PracticeSettings.currentPreferenceVersion
            try expect(saved["preferenceVersion"] as? Int == expectedVersion,
                       "Launching a migrated session did not immediately commit \(fileName)'s one-time version marker")
        }
        print("PASS: old defaults migrate once and commit version markers on launch without disturbing unrelated custom choices")

        upgradedDefaults.targetAlignmentMilliseconds = 800
        var explicitlyChosenOldValues = upgradedDefaults.displaySettings
        explicitlyChosenOldValues.noteOpacity = 0.92
        explicitlyChosenOldValues.highlightOpacity = 0.64
        explicitlyChosenOldValues.feedbackOpacity = 0.96
        explicitlyChosenOldValues.templateOpacity = 0.30
        upgradedDefaults.displaySettings = explicitlyChosenOldValues
        for _ in 0..<3 {
            let relaunch = makeSession("defaults-migration")
            try expect(relaunch.targetAlignmentMilliseconds == 800 && relaunch.displaySettings.noteOpacity == 0.92
                       && relaunch.displaySettings.highlightOpacity == 0.64 && relaunch.displaySettings.feedbackOpacity == 0.96
                       && relaunch.displaySettings.templateOpacity == 0.30,
                       "A current-version user choice equal to an old default was reset on a later launch")
        }
        print("PASS: explicitly choosing former defaults after migration survives repeated session relaunches")

        let customMigrationRoot = root.appending(path: "custom-preferences-migration")
        try FileManager.default.createDirectory(at: customMigrationRoot, withIntermediateDirectories: true)
        try Data(#"{"mode":"waitForNotes","automaticHandSplit":false,"splitPitch":57,"showFingering":true,"targetAlignmentMilliseconds":1200}"#.utf8)
            .write(to: customMigrationRoot.appending(path: "practice-settings.json"))
        try Data(#"{"contrastVersion":1,"noteOpacity":0.23,"highlightOpacity":0.41,"feedbackOpacity":0.73,"templateOpacity":0.17}"#.utf8)
            .write(to: customMigrationRoot.appending(path: "display-settings.json"))
        for _ in 0..<2 {
            let customRelaunch = makeSession("custom-preferences-migration")
            try expect(customRelaunch.targetAlignmentMilliseconds == 1200 && customRelaunch.splitPitch == 57
                       && customRelaunch.showFingering && !customRelaunch.automaticHandSplit
                       && customRelaunch.displaySettings.noteOpacity == 0.23 && customRelaunch.displaySettings.highlightOpacity == 0.41
                       && customRelaunch.displaySettings.feedbackOpacity == 0.73 && customRelaunch.displaySettings.templateOpacity == 0.17,
                       "A legacy explicit custom alignment or opacity value was overwritten during migration")
        }
        let missingAlignment = try JSONDecoder().decode(PracticeSettings.self, from:
            Data(#"{"mode":"automatic","automaticHandSplit":true,"splitPitch":60,"showFingering":false}"#.utf8))
        try expect(missingAlignment.targetAlignmentMilliseconds == 2000 && missingAlignment.preferenceVersion == 2,
                   "Older preferences missing the alignment field did not acquire the new default and version")
        print("PASS: legacy custom alignment/opacities are preserved and missing alignment fields use the new default")

        let captureGate = makeSession("finger-calibration-play-gate")
        captureGate.install(PianoSong(title: "Capture blocks playback", notes: [
            .init(id: 0, pitch: 60, start: 0, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano")]))
        captureGate.calibration.isFingerCalibrationActive = true
        captureGate.play()
        try expect(!captureGate.isPlaying && captureGate.hitCount == 0 && captureGate.errorMessage != nil,
                   "Playback started while fingertip calibration was actively collecting a point")
        captureGate.calibration.isFingerCalibrationActive = false
        captureGate.calibration.hasFingerCalibrationFirstPoint = true
        captureGate.play()
        try expect(!captureGate.isPlaying && captureGate.hitCount == 0,
                   "Playback started with only one endpoint of the new piano placement captured")
        captureGate.calibration.hasFingerCalibrationFirstPoint = false
        captureGate.play()
        try expect(captureGate.isPlaying, "Cancelling or completing fingertip calibration left playback permanently blocked")
        print("PASS: playback waits for active or unfinished fingertip calibration and resumes once that workflow is resolved")

        let octaveCueSong = PianoSong(title: "Both-hand octaves before another chord", notes: [
            .init(id: 0, pitch: 36, start: 1, duration: 0.8, track: 0),
            .init(id: 1, pitch: 48, start: 1, duration: 0.8, track: 0),
            .init(id: 2, pitch: 72, start: 1, duration: 0.8, track: 1),
            .init(id: 3, pitch: 84, start: 1, duration: 0.8, track: 1),
            .init(id: 4, pitch: 41, start: 1.5, duration: 0.8, track: 0),
            .init(id: 5, pitch: 53, start: 1.5, duration: 0.8, track: 0),
            .init(id: 6, pitch: 77, start: 1.5, duration: 0.8, track: 1),
            .init(id: 7, pitch: 89, start: 1.5, duration: 0.8, track: 1)
        ], tracks: [.init(id: 0, name: "Left hand"), .init(id: 1, name: "Right hand")])
        var octaveCueHost = 15_000.0
        let octaveCues = PianoSession(libraryDirectory: root.appending(path: "current-octave-keyboard-cues"), loadsDemo: false, now: { octaveCueHost })
        octaveCues.install(octaveCueSong)
        try expect(octaveCues.targetAlignmentMilliseconds == 2000
                   && octaveCues.targetPreviewNoteIDs == Set(0...7)
                   && octaveCues.keyboardTargetNoteIDs == [0, 1, 2, 3],
                   "Waiting keyboard cues included the following chord or removed it from the original two-second preview")
        octaveCues.play()
        octaveCueHost += 0.2
        for pitch in [36, 48] {
            octaveCues.receive(.init(kind: .noteOn, note: pitch, velocity: 100, timestamp: octaveCueHost))
            octaveCues.receive(.init(kind: .noteOff, note: pitch, timestamp: octaveCueHost))
        }
        octaveCueHost = 15_001.1
        octaveCues.updatePractice()
        try expect(octaveCues.isWaiting && octaveCues.hitCount == 0 && octaveCues.activeNotes.isEmpty
                   && octaveCues.matchedWaitingPitches == [36, 48]
                   && octaveCues.keyboardTargetNoteIDs == [2, 3]
                   && Set(4...7).isSubset(of: octaveCues.targetPreviewNoteIDs)
                   && octaveCueSong.notes.filter { $0.start == 1.5 }.allSatisfy {
                       octaveCues.notePresentation(for: $0).role == .next
                   }, "Released left-hand octaves lost progress or exposed next-chord keys before the right hand finished")
        octaveCues.receive(.init(kind: .noteOn, note: 72, velocity: 100, timestamp: octaveCueHost))
        octaveCues.receive(.init(kind: .noteOff, note: 72, timestamp: octaveCueHost))
        try expect(octaveCues.keyboardTargetNoteIDs == [3] && octaveCues.hitCount == 0,
                   "Completing only part of the right-hand octave advanced the keyboard cue to another chord")
        octaveCues.receive(.init(kind: .noteOn, note: 84, velocity: 100, timestamp: octaveCueHost))
        try expect(octaveCues.hitCount == 4 && !octaveCues.isWaiting
                   && octaveCues.currentTargetNoteIDs == [4, 5, 6, 7]
                   && octaveCues.keyboardTargetNoteIDs == [4, 5, 6, 7],
                   "The keyboard did not move directly to the next chord after both hands finished the current octaves")
        print("PASS: wait-mode keyboard cues show only unfinished current-hand octaves while the next chord stays in score preview")

        var futureCueHost = 16_000.0
        let futureCues = PianoSession(libraryDirectory: root.appending(path: "early-future-keyboard-cues"), loadsDemo: false, now: { futureCueHost })
        let futureCueSong = PianoSong(title: "Early input without future target keys", notes: [
            .init(id: 0, pitch: 48, start: 1, duration: 0.7),
            .init(id: 1, pitch: 72, start: 1, duration: 0.7),
            .init(id: 2, pitch: 67, start: 1.5, duration: 0.7)
        ], tracks: [.init(id: 0, name: "Piano")])
        futureCues.install(futureCueSong)
        futureCues.play()
        futureCueHost += 0.9
        futureCues.receive(.init(kind: .noteOn, note: 48, velocity: 100, timestamp: futureCueHost))
        futureCues.receive(.init(kind: .noteOff, note: 48, timestamp: futureCueHost))
        futureCueHost += 0.05
        futureCues.receive(.init(kind: .noteOn, note: 67, velocity: 100, timestamp: futureCueHost))
        let acceptedFuture = futureCues.notePresentation(for: futureCueSong.notes[2])
        try expect(futureCues.keyboardTargetNoteIDs == [1] && futureCues.activeNotes == [67]
                   && futureCues.heldCorrectNotes == [67] && acceptedFuture.isPendingEarly
                   && acceptedFuture.isHeld && acceptedFuture.progress == .accepted,
                   "Hiding future target keys interfered with physical feedback or valid early future-note acceptance")
        futureCues.receive(.init(kind: .noteOff, note: 67, timestamp: futureCueHost))
        try expect(futureCues.keyboardTargetNoteIDs == [1]
                   && futureCues.targetPreviewNoteIDs == [1, 2]
                   && futureCues.notePresentation(for: futureCueSong.notes[2]).progress == .unplayed
                   && futureCues.activeNotes.isEmpty && futureCues.heldCorrectNotes.isEmpty,
                   "Releasing a future candidate either lost its preview eligibility or added a distracting future keyboard cue")
        futureCueHost += 0.01
        futureCues.receive(.init(kind: .noteOn, note: 67, velocity: 100, timestamp: futureCueHost))
        try expect(futureCues.notePresentation(for: futureCueSong.notes[2]).progress == .accepted
                   && futureCues.keyboardTargetNoteIDs == [1] && futureCues.wrongCount == 0,
                   "A cancelled future candidate could no longer be retried inside the unchanged two-second window")
        futureCueHost = 16_001.1
        futureCues.receive(.init(kind: .noteOn, note: 72, velocity: 100, timestamp: futureCueHost))
        try expect(futureCues.hitCount == 2 && futureCues.currentTargetNoteIDs == [2]
                   && futureCues.keyboardTargetNoteIDs.isEmpty && futureCues.activeNotes.contains(67),
                   "An already-held early future note was requested again as a keyboard target after promotion")
        futureCueHost = 16_001.7
        futureCues.updatePractice()
        try expect(futureCues.hitCount == 3 && futureCues.wrongCount == 0,
                   "Limiting keyboard cues altered future-buffer consumption or scoring")
        print("PASS: future input still accepts, cancels and retries normally without appearing as a wait-mode keyboard target")

        for rate in [0.5, 2.0] {
            var autoCueHost = 17_000.0
            let autoCues = PianoSession(libraryDirectory: root.appending(path: "automatic-keyboard-cues-\(rate)"), loadsDemo: false, now: { autoCueHost })
            autoCues.setPracticeMode(.automatic)
            autoCues.install(octaveCueSong)
            autoCues.setRate(rate)
            try expect(autoCues.keyboardTargetNoteIDs == autoCues.targetPreviewNoteIDs
                       && autoCues.keyboardTargetNoteIDs == Set(0...7),
                       "Automatic keyboard guidance no longer retained the original multi-onset preview")
            autoCues.play()
            autoCueHost += 3 + 0.9 / rate
            autoCues.receive(.init(kind: .noteOn, note: 36, velocity: 100, timestamp: autoCueHost))
            try expect(autoCues.hitCount == 1 && autoCues.keyboardTargetNoteIDs == autoCues.targetPreviewNoteIDs
                       && !autoCues.keyboardTargetNoteIDs.contains(0)
                       && Set(4...7).isSubset(of: autoCues.keyboardTargetNoteIDs),
                       "The shared keyboard API changed automatic matching, rate-dependent preview, or completed-onset removal")
        }
        print("PASS: automatic keyboard guidance remains identical to its existing preview before and after scoring at both playback rates")

        for rate in [0.5, 1.0, 1.2] {
            var leadHost = 18_000.0
            let lead = PianoSession(libraryDirectory: root.appending(path: "automatic-lead-in-\(rate)"), loadsDemo: false, now: { leadHost })
            lead.setPracticeMode(.automatic)
            lead.targetAlignmentMilliseconds = 50
            let firstNote = PianoNote(id: 0, pitch: 60, start: 0, duration: 1)
            lead.install(PianoSong(title: "Three real seconds", notes: [firstNote], tracks: [.init(id: 0, name: "Piano")]))
            lead.setRate(rate)
            lead.play()
            try expect(lead.isPlaying && lead.preparationCountdown == 3 && abs(lead.songTime + 3 * rate) < 0.000001,
                       "Automatic start did not create a moving three-second visual lead-in at rate \(rate)")
            lead.receive(.init(kind: .noteOn, note: 90, velocity: 100, timestamp: leadHost))
            leadHost = 18_001.1
            lead.updatePractice()
            try expect(lead.preparationCountdown == 2 && lead.uiTime == 0 && abs(lead.songTime + 1.9 * rate) < 0.000001
                       && lead.hitCount == 0 && lead.wrongCount == 0 && lead.missedCount == 0 && lead.activeNotes == [90],
                       "Preparation failed to scroll without advancing the score, or lost physical input feedback")
            leadHost = 18_002.999
            lead.updatePractice()
            lead.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: leadHost))
            try expect(lead.preparationCountdown == 1 && lead.hitCount == 0 && lead.wrongCount == 0 && lead.missedCount == 0
                       && !lead.notePresentation(for: firstNote).isHeld,
                       "A pre-start press was scored inside the early-alignment window")
            lead.receive(.init(kind: .noteOff, note: 60, timestamp: leadHost))
            // Complete at receive-time, without relying on a frame arriving at the deadline.
            leadHost = 18_003.02
            lead.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: 18_002.999))
            try expect(lead.preparationCountdown == 0 && lead.hitCount == 0 && lead.wrongCount == 0
                       && abs(lead.songTime - 0.02 * rate) < 0.000001,
                       "A late-delivered preparation event scored, or a delayed frame shifted the playback origin")
            lead.receive(.init(kind: .noteOff, note: 60, timestamp: leadHost))
            lead.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: leadHost))
            try expect(lead.hitCount == 1 && lead.wrongCount == 0 && lead.missedCount == 0,
                       "The first real onset after the countdown failed to score")
        }
        print("PASS: automatic lead-in scrolls for three real seconds at every rate and ignores preparation events even when delivered late")

        var controlsHost = 19_000.0
        let controls = PianoSession(libraryDirectory: root.appending(path: "lead-in-controls"), loadsDemo: false, now: { controlsHost })
        let controlsSong = PianoSong(title: "Prepare after resume and seek", notes: [
            .init(id: 0, pitch: 60, start: 0, duration: 1), .init(id: 1, pitch: 64, start: 10, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano")])
        controls.setPracticeMode(.automatic)
        controls.install(controlsSong)
        controls.seek(to: 10)
        controls.play()
        controlsHost += 0.8
        controls.setRate(0.5)
        try expect(abs(controls.songTime - 8.9) < 0.000001,
                   "Changing speed restarted the preparation deadline or lost its score destination")
        controlsHost += 1.2
        controls.updatePractice()
        try expect(controls.preparationCountdown == 1 && controls.uiTime == 10 && abs(controls.songTime - 9.5) < 0.000001,
                   "Preparation duration changed with playback rate")
        controls.pause()
        controlsHost += 5
        controls.updatePractice()
        try expect(!controls.isPlaying && controls.preparationCountdown == 0 && controls.songTime == 10,
                   "Pausing a countdown lost the intended score position or let an old deadline start playback")
        controls.play()
        controlsHost += 2
        controls.seek(to: 5)
        try expect(controls.isPlaying && controls.preparationCountdown == 3 && controls.uiTime == 5
                   && abs(controls.songTime - 3.5) < 0.000001,
                   "A live seek did not restart preparation at its selected destination")
        controlsHost += 1
        controls.play()
        controlsHost += 2
        controls.updatePractice()
        try expect(controls.isPlaying && controls.preparationCountdown == 0 && controls.songTime == 5,
                   "A repeated play call restarted a running countdown or a live seek skipped its destination")
        controls.pause()
        controls.play()
        controlsHost += 0.5
        controls.setPracticeMode(.waitForNotes)
        try expect(!controls.isPlaying && controls.preparationCountdown == 0 && controls.songTime == 5,
                   "Switching out of automatic preparation copied the visual rewind instead of the selected score position")
        controls.install(controlsSong)
        controls.play()
        controls.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: controlsHost))
        try expect(controls.preparationCountdown == 0 && controls.hitCount == 1,
                   "Automatic preparation accidentally delayed wait-for-notes scoring")
        controls.setPracticeMode(.automatic)
        controls.play()
        controls.restart()
        controlsHost += 10
        controls.updatePractice()
        try expect(!controls.isPlaying && controls.preparationCountdown == 0 && controls.songTime == 0 && controls.hitCount == 0,
                   "Returning to the beginning kept a preparation deadline or old score")
        controls.play()
        controls.install(controlsSong)
        controlsHost += 10
        controls.updatePractice()
        try expect(!controls.isPlaying && controls.preparationCountdown == 0 && controls.songTime == 0,
                   "Loading a song failed to cancel the old preparation")
        controls.setRate(1)
        controls.play()
        controlsHost += 3.25
        controls.setPracticeMode(.waitForNotes)
        try expect(!controls.isPlaying && controls.preparationCountdown == 0 && abs(controls.songTime - 0.25) < 0.000001,
                   "A mode change just after the preparation deadline rewound the real score position")
        print("PASS: preparation handles speed, pause, resume, live seek, duplicate play, restart, mode and song changes without stale starts")

        let layoutRoot = root.appending(path: "library-layout")
        try FileManager.default.createDirectory(at: layoutRoot, withIntermediateDirectories: true)
        let layoutURL = layoutRoot.appending(path: "library-preferences.json")
        try Data(#"{"sortOrder":"nameDescending"}"#.utf8).write(to: layoutURL)
        let oldLayout = makeSession("library-layout")
        try expect(oldLayout.librarySortOrder == .nameDescending && oldLayout.libraryDisplayMode == .cards && oldLayout.libraryColumnCount == 3,
                   "Adding cards lost a legacy sort preference or failed to choose the three-column default")
        oldLayout.libraryDisplayMode = .list
        oldLayout.libraryColumnCount = 4
        let savedLayout = makeSession("library-layout")
        try expect(savedLayout.libraryDisplayMode == .list && savedLayout.libraryColumnCount == 4 && savedLayout.librarySortOrder == .nameDescending,
                   "Library layout and column preferences failed to survive a restart")
        savedLayout.libraryColumnCount = -10
        try expect(savedLayout.libraryColumnCount == 2, "A column value below the supported range was not bounded")
        savedLayout.libraryColumnCount = 100
        try expect(savedLayout.libraryColumnCount == 4, "A column value above the supported range was not bounded")
        try Data(#"{"sortOrder":"lastPlayed","displayMode":"cards","columnCount":0}"#.utf8).write(to: layoutURL)
        let boundedLayout = makeSession("library-layout")
        try expect(boundedLayout.libraryColumnCount == 2 && boundedLayout.libraryDisplayMode == .cards && boundedLayout.librarySortOrder == .lastPlayed,
                   "An old or edited layout preference produced an invalid grid or discarded the sort")
        print("PASS: library cards default to three columns, legacy sorts survive, and layout/column preferences persist within safe bounds")

        var gradeHost = 20_000.0
        let graded = PianoSession(libraryDirectory: root.appending(path: "automatic-percentages"), loadsDemo: false, now: { gradeHost })
        graded.setPracticeMode(.automatic)
        graded.targetAlignmentMilliseconds = 50
        graded.install(PianoSong(title: "Automatic percentages", notes: [
            .init(id: 0, pitch: 60, start: 0, duration: 1),
            .init(id: 1, pitch: 64, start: 2, duration: 1),
            .init(id: 2, pitch: 67, start: 4, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano")]))
        graded.play()
        gradeHost += 2
        graded.receive(.init(kind: .noteOn, note: 90, velocity: 100, timestamp: gradeHost))
        graded.receive(.init(kind: .noteOff, note: 90, timestamp: gradeHost))
        try expect(graded.completionPercentage == 0 && graded.timingPercentage == nil && graded.wrongCount == 0,
                   "Automatic preparation created a completion or timing score")
        gradeHost = 20_003
        graded.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: gradeHost))
        graded.receive(.init(kind: .noteOn, note: 60, velocity: 100, channel: 1, timestamp: gradeHost))
        try expect(graded.hitCount == 1 && graded.wrongCount == 0 && graded.completionPercentage == 100 && graded.timingPercentage == nil,
                   "Duplicate multi-channel note-ons changed the percentage or prematurely graded a hold")
        gradeHost += 1
        graded.receive(.init(kind: .noteOff, note: 60, channel: 0, timestamp: gradeHost))
        try expect(graded.timingEvaluatedNoteCount == 0, "The first channel release ended a key still physically held on another channel")
        graded.receive(.init(kind: .noteOff, note: 60, channel: 1, timestamp: gradeHost))
        try expect(abs((graded.timingPercentage ?? -1) - 100) < 0.000001 && graded.timingEvaluatedNoteCount == 1,
                   "A correct physical release failed to finish the timing sample")
        graded.receive(.init(kind: .noteOn, note: 90, velocity: 100, timestamp: gradeHost))
        try expect(graded.completionPercentage == 50, "Wrong notes were omitted from the requested denominator")
        gradeHost = 20_006
        graded.updatePractice()
        try expect(graded.missedCount == 1 && abs(graded.completionPercentage - 100.0 / 3) < 0.000001,
                   "Missed notes were omitted from the requested denominator")
        graded.receive(.init(kind: .noteOn, note: 64, velocity: 100, timestamp: 20_005))
        graded.receive(.init(kind: .noteOff, note: 64, timestamp: 20_006))
        try expect(graded.hitCount == 2 && graded.missedCount == 0 && graded.wrongCount == 1
                   && abs(graded.completionPercentage - 200.0 / 3) < 0.000001
                   && abs((graded.timingPercentage ?? -1) - 100) < 0.000001 && graded.timingEvaluatedNoteCount == 2,
                   "Timestamp-correct late delivery did not recover both percentages without double-counting")
        graded.seek(to: 0)
        try expect(graded.completionPercentage == 0 && graded.timingPercentage == nil && graded.timingEvaluatedNoteCount == 0,
                   "Seeking retained a previous run's completion or timing score")
        print("PASS: percentages use correct/wrong/missed counts, physical multi-channel releases, source timestamps and seek resets")

        var arpeggioGradeHost = 21_000.0
        let arpeggioGrade = PianoSession(libraryDirectory: root.appending(path: "arpeggio-percentages"), loadsDemo: false, now: { arpeggioGradeHost })
        arpeggioGrade.install(PianoSong(title: "Released chord timing", notes: [
            .init(id: 0, pitch: 60, start: 0, duration: 0.2),
            .init(id: 1, pitch: 64, start: 0, duration: 0.2),
            .init(id: 2, pitch: 60, start: 0, duration: 0.2, track: 1)
        ], tracks: [.init(id: 0, name: "Piano"), .init(id: 1, name: "Double")]))
        arpeggioGrade.play()
        arpeggioGrade.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: arpeggioGradeHost))
        arpeggioGradeHost += 0.2
        arpeggioGrade.receive(.init(kind: .noteOff, note: 60, timestamp: arpeggioGradeHost))
        try expect(arpeggioGrade.timingEvaluatedNoteCount == 0 && arpeggioGrade.hitCount == 0,
                   "An unfinished chord's timing candidate was committed too early")
        arpeggioGradeHost = 21_000.29
        arpeggioGrade.receive(.init(kind: .noteOn, note: 64, velocity: 100, timestamp: arpeggioGradeHost))
        try expect(arpeggioGrade.hitCount == 2 && arpeggioGrade.completionPercentage == 100
                   && arpeggioGrade.timingEvaluatedNoteCount == 1,
                   "Released arpeggio notes lost timing provenance or score aliases counted twice")
        arpeggioGradeHost = 21_000.49
        arpeggioGrade.receive(.init(kind: .noteOn, note: 64, velocity: 0, timestamp: arpeggioGradeHost))
        try expect(arpeggioGrade.timingEvaluatedNoteCount == 2 && abs((arpeggioGrade.timingPercentage ?? -1) - 75) < 0.00001,
                   "Wait-mode timing used its frozen score clock, lost the first release, or ignored velocity-zero note-off")
        print("PASS: released arpeggios grade real onset/release timing after chord completion, without changing acceptance or counting aliases twice")

        var futureGradeHost = 22_000.0
        let futureGrade = PianoSession(libraryDirectory: root.appending(path: "future-percentage-cancellation"), loadsDemo: false, now: { futureGradeHost })
        futureGrade.install(PianoSong(title: "Revoked early future", notes: [
            .init(id: 0, pitch: 60, start: 0, duration: 1), .init(id: 1, pitch: 64, start: 0, duration: 1),
            .init(id: 2, pitch: 67, start: 1, duration: 0.2)
        ], tracks: [.init(id: 0, name: "Piano")]))
        futureGrade.play()
        futureGradeHost += 0.1
        futureGrade.receive(.init(kind: .noteOn, note: 67, velocity: 100, timestamp: futureGradeHost))
        futureGradeHost += 0.1
        futureGrade.receive(.init(kind: .noteOff, note: 67, timestamp: futureGradeHost))
        futureGrade.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: futureGradeHost))
        futureGradeHost += 1
        futureGrade.receive(.init(kind: .noteOff, note: 60, timestamp: futureGradeHost))
        futureGrade.receive(.init(kind: .noteOn, note: 64, velocity: 100, timestamp: futureGradeHost))
        futureGradeHost += 0.1
        futureGrade.receive(.init(kind: .noteOff, note: 64, timestamp: futureGradeHost))
        try expect(futureGrade.hitCount == 2 && futureGrade.wrongCount == 0 && futureGrade.timingEvaluatedNoteCount == 2,
                   "A revoked future candidate contributed an invalid timing sample or altered relaxed chord acceptance")
        print("PASS: revoked future candidates cannot contribute to timing percentages")

        var pauseGradeHost = 23_000.0
        let pauseGrade = PianoSession(libraryDirectory: root.appending(path: "interrupted-timing"), loadsDemo: false, now: { pauseGradeHost })
        pauseGrade.install(PianoSong(title: "Physical releases only", notes: [
            .init(id: 0, pitch: 60, start: 0, duration: 1), .init(id: 1, pitch: 64, start: 2, duration: 1)
        ], tracks: [.init(id: 0, name: "Piano")]))
        pauseGrade.play()
        pauseGrade.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: pauseGradeHost))
        pauseGradeHost += 0.2
        pauseGrade.pause()
        pauseGradeHost += 5
        pauseGrade.receive(.init(kind: .noteOff, note: 60, timestamp: pauseGradeHost))
        try expect(pauseGrade.hitCount == 1 && pauseGrade.timingEvaluatedNoteCount == 0,
                   "Pause time was graded as a bad physical release")
        pauseGrade.restart()
        pauseGrade.play()
        pauseGrade.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: pauseGradeHost))
        pauseGrade.receive(.init(kind: .controlChange, controller: 64, value: 127, timestamp: pauseGradeHost))
        pauseGradeHost += 1
        pauseGrade.receive(.init(kind: .noteOff, note: 60, timestamp: pauseGradeHost))
        try expect(pauseGrade.pedalDown && pauseGrade.timingEvaluatedNoteCount == 1
                   && abs((pauseGrade.timingPercentage ?? -1) - 100) < 0.000001,
                   "Sustain delayed physical-release scoring")
        pauseGradeHost += 1
        pauseGrade.receive(.init(kind: .noteOn, note: 64, velocity: 100, timestamp: pauseGradeHost))
        pauseGrade.receive(.init(kind: .allNotesOff, controller: 123, timestamp: pauseGradeHost))
        try expect(pauseGrade.timingEvaluatedNoteCount == 1 && pauseGrade.hitCount == 2,
                   "A panic/all-notes-off controller invented a scored physical release")
        print("PASS: pause excludes interrupted holds, sustain does not delay grading, and panic controllers never invent releases")

        for rate in [0.5, 1.2] {
            for offset in [-150.0, 0, 150] {
                var scaledHost = 24_000.0
                let scaled = PianoSession(libraryDirectory: root.appending(path: "scaled-timing-\(rate)-\(offset)"), loadsDemo: false, now: { scaledHost })
                scaled.setPracticeMode(.automatic)
                scaled.setRate(rate)
                scaled.inputOffsetMilliseconds = offset
                scaled.install(PianoSong(title: "Real-time timing scale", notes: [
                    .init(id: 0, pitch: 60, start: 1, duration: 1)
                ], tracks: [.init(id: 0, name: "Piano")]))
                scaled.play()
                scaledHost = 24_003 + 1 / rate - offset / 1000
                scaled.receive(.init(kind: .noteOn, note: 60, velocity: 100, timestamp: scaledHost))
                scaledHost += 1 / rate
                scaled.receive(.init(kind: .noteOff, note: 60, timestamp: scaledHost))
                try expect(scaled.hitCount == 1 && scaled.timingEvaluatedNoteCount == 1
                           && abs((scaled.timingPercentage ?? -1) - 100) < 0.000001,
                           "Timing grading ignored playback rate or applied input calibration to only one physical edge")
            }
        }
        print("PASS: timing percentages honor real-time playback rates and apply positive/negative input offsets to both onset and release")

        let trackMigrationRoot = root.appending(path: "track-default-migration")
        try FileManager.default.createDirectory(at: trackMigrationRoot, withIntermediateDirectories: true)
        let trackSettingsURL = trackMigrationRoot.appending(path: "display-settings.json")
        try Data(#"{"preferenceVersion":2,"rollLengthMeters":1.1,"lookAheadSeconds":5,"noteOpacity":0.92}"#.utf8).write(to: trackSettingsURL)
        let newTrackDefaults = makeSession("track-default-migration")
        try expect(newTrackDefaults.displaySettings.rollLengthMeters == 1.5 && newTrackDefaults.displaySettings.lookAheadSeconds == 5
                   && newTrackDefaults.displaySettings.noteOpacity == 0.92,
                   "The track upgrade reset a version-two opacity choice or failed to apply the new default")
        let committedTrackSettings = try JSONSerialization.jsonObject(with: Data(contentsOf: trackSettingsURL)) as! [String: Any]
        try expect(committedTrackSettings["preferenceVersion"] as? Int == PianoDisplaySettings.currentPreferenceVersion,
                   "The track default migration marker was not committed on launch")
        newTrackDefaults.displaySettings.rollLengthMeters = 1.1
        for _ in 0..<3 {
            let trackRelaunch = makeSession("track-default-migration")
            try expect(trackRelaunch.displaySettings.rollLengthMeters == 1.1 && trackRelaunch.displaySettings.lookAheadSeconds == 5,
                       "An explicit return to the former track length was migrated again")
        }
        print("PASS: 150cm track defaults migrate and commit once while five-second preview and version-two custom choices persist")
    }
}
