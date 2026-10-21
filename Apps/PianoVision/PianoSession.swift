import Foundation
import Observation
import PianoCore
import PianoLink

struct LibraryEntry: Codable, Identifiable {
    let id: UUID
    let title: String
    let fileName: String
    let noteCount: Int
    let duration: Double
    let importID: UUID?
    var isFavorite: Bool
    var importedAt: Date?
    var lastPlayedAt: Date?

    init(id: UUID, title: String, fileName: String, noteCount: Int, duration: Double,
         importID: UUID? = nil, isFavorite: Bool = false, importedAt: Date? = nil, lastPlayedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.noteCount = noteCount
        self.duration = duration
        self.importID = importID
        self.isFavorite = isFavorite
        self.importedAt = importedAt
        self.lastPlayedAt = lastPlayedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, fileName, noteCount, duration, importID, isFavorite, importedAt, lastPlayedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        fileName = try values.decode(String.self, forKey: .fileName)
        noteCount = try values.decode(Int.self, forKey: .noteCount)
        duration = try values.decode(Double.self, forKey: .duration)
        importID = try values.decodeIfPresent(UUID.self, forKey: .importID)
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        importedAt = try values.decodeIfPresent(Date.self, forKey: .importedAt)
        lastPlayedAt = try values.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
    }
}

enum LibrarySortOrder: String, Codable, CaseIterable, Identifiable {
    case importedNewest, importedOldest, nameAscending, nameDescending, lastPlayed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .importedNewest: "导入时间 · 从新到旧"
        case .importedOldest: "导入时间 · 从旧到新"
        case .nameAscending: "名称 · 升序"
        case .nameDescending: "名称 · 降序"
        case .lastPlayed: "最近打开"
        }
    }
}

enum LibraryDisplayMode: String, Codable, CaseIterable, Identifiable {
    case list, cards
    var id: String { rawValue }
    var title: String { self == .list ? "列表" : "卡片" }
}

private struct LibraryPreferences: Codable {
    var sortOrder: LibrarySortOrder
    var displayMode: LibraryDisplayMode
    var columnCount: Int

    init(sortOrder: LibrarySortOrder, displayMode: LibraryDisplayMode, columnCount: Int) {
        self.sortOrder = sortOrder
        self.displayMode = displayMode
        self.columnCount = min(4, max(2, columnCount))
    }

    private enum CodingKeys: String, CodingKey { case sortOrder, displayMode, columnCount }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sortOrder = try values.decodeIfPresent(LibrarySortOrder.self, forKey: .sortOrder) ?? .importedNewest
        displayMode = try values.decodeIfPresent(LibraryDisplayMode.self, forKey: .displayMode) ?? .cards
        columnCount = min(4, max(2, try values.decodeIfPresent(Int.self, forKey: .columnCount) ?? 3))
    }
}

struct RecentInput: Identifiable {
    let id = UUID()
    let pitch: Int
    let velocity: Int
    let channel: Int
    let label: String
}

enum PianoNoteRole: Equatable, Sendable { case upcoming, current, next }
enum PianoNoteProgress: Equatable, Sendable { case unplayed, accepted, completed }

/// Score progress and a physical key hold are independent: a released arpeggio
/// may be accepted, while a future candidate still needs to remain held.
struct PianoNotePresentation: Equatable, Sendable {
    let role: PianoNoteRole
    let progress: PianoNoteProgress
    let isHeld: Bool
    let needsRestrike: Bool
    let isPendingEarly: Bool

    var feedback: PianoNoteFeedback {
        progress != .unplayed ? .matched : isHeld ? .pressed : .normal
    }
}

@MainActor @Observable
final class PianoSession {
    let minMIDINote = 21
    let keyCount = 88
    let bridge = BridgeClient()
    var calibration = SpatialCalibration()
    var song: PianoSong?
    var songRevision = 0
    var enabledTrackIDs: Set<Int> = []
    var displaySettings = PianoDisplaySettings() {
        didSet {
            guard !restoringPreferences else { return }
            persistDisplaySettings()
        }
    }
    var inputChannel = -1
    var inputOffsetMilliseconds = 0.0 { didSet { performanceGrade.interrupt() } }
    var isImmersiveActive = false
    var errorMessage: String?
    var isImporting = false
    var library: [LibraryEntry] = []
    var librarySortOrder: LibrarySortOrder = .importedNewest {
        didSet { if !restoringPreferences { persistLibraryPreferences() } }
    }
    var libraryDisplayMode: LibraryDisplayMode = .cards {
        didSet { if !restoringPreferences { persistLibraryPreferences() } }
    }
    var libraryColumnCount = 3 {
        didSet {
            let bounded = min(4, max(2, libraryColumnCount))
            if libraryColumnCount != bounded { libraryColumnCount = bounded }
            if !restoringPreferences { persistLibraryPreferences() }
        }
    }
    var recentInputs: [RecentInput] = []
    var hitCount = 0
    var wrongCount = 0
    var missedCount = 0
    var lastTimingMilliseconds: Double?
    var pedalDown = false
    var uiTime = 0.0
    private(set) var practiceMode: PracticeMode = .waitForNotes
    var targetAlignmentMilliseconds = PracticeSettings.defaultTargetAlignmentMilliseconds {
        didSet {
            guard !restoringPreferences else { return }
            waitEngine.setEarlyInputWindow(alignmentWindowSeconds, at: hostTime)
            matcher.setTimingTolerance(alignmentWindowSeconds)
            invalidatePendingFeedback()
            persistSettings()
        }
    }
    private var alignmentWindowSeconds: Double {
        Self.validatedMilliseconds(targetAlignmentMilliseconds, fallback: PracticeSettings.defaultTargetAlignmentMilliseconds) / 1000
    }
    var automaticHandSplit = true { didSet { if !restoringPreferences { rebuildHands(); persistSettings() } } }
    var splitPitch = 60 { didSet { if !restoringPreferences { rebuildHands(); persistSettings() } } }
    var showFingering = false {
        didSet {
            guard !restoringPreferences else { return }
            annotationRevision += 1
            persistSettings()
            if showFingering && generatedFingers.isEmpty { generateFingering() }
            if !showFingering { cancelFingering() }
        }
    }
    private(set) var trackHands: [Int: PianoHand] = [:]
    private(set) var annotationRevision = 0
    private(set) var isGeneratingFingering = false
    private(set) var unsupportedFingeringCount = 0

    @ObservationIgnored private let timeSource: () -> Double
    private var hostTime: Double { timeSource() }
    private var clock = PlaybackClock()
    private struct AutomaticLeadIn {
        let position: Double
        let deadline: Double
    }
    private var automaticLeadIn: AutomaticLeadIn?
    private(set) var preparationCountdown = 0
    private var waitEngine = WaitModeEngine(notes: [], inputTolerance: .relaxed)
    private var matcher = PerformanceMatcher(notes: [])
    private var performanceGrade = PerformanceGrade()
    var completionPercentage: Double {
        PerformanceGrade.completionPercentage(correct: hitCount, wrong: wrongCount, missed: missedCount)
    }
    var timingPercentage: Double? { performanceGrade.timingPercentage }
    var timingEvaluatedNoteCount: Int { performanceGrade.evaluatedNoteCount }
    private var timingHostTime: Double {
        hostTime + (practiceMode == .automatic ? inputOffsetMilliseconds / 1000 : 0)
    }
    private var keyState = MIDIKeyState()
    private var correctUntil: [Int: Double] = [:]
    private var wrongUntil: [Int: Double] = [:]
    private(set) var heldCorrectNotes: Set<Int> = []
    private(set) var heldWrongNotes: Set<Int> = []
    private var completedHeldNotes: Set<Int> = []
    private var inputPulseUntil: [Int: Double] = [:]
    /// A physical onset owns only the exact score identities it was assigned.
    /// This association survives a gate advance, but never flows to a repeat.
    private var heldNoteIDsByPitch: [Int: Set<Int>] = [:]
    private var scoringEpochHostTime = 0.0
    private var playableNoteCount = 0
    private var canonicalNoteIDs: [Int: Int] = [:]
    private var aliasesByCanonicalNoteID: [Int: Set<Int>] = [:]
    private var selectedNotesByID: [Int: PianoNote] = [:]
    private var presentationNotes: [PianoNote] = []
    private var presentationMaximumEnds: [Double] = []
    private let libraryURL: URL
    private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var fingeringTask: Task<Void, Never>?
    private var generationID = UUID()
    private var noteHands: [Int: PianoHand] = [:]
    private var generatedFingers: [Int: Int] = [:]
    private var fingerOverrides: [Int: Int] = [:]
    private var currentSongKey: String?
    private var restoringPreferences = true

    var currentLibraryEntryID: UUID? {
        guard let key = currentSongKey, let id = UUID(uuidString: key), library.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func libraryEntries(matching query: String, favoritesOnly: Bool) -> [LibraryEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return library.enumerated().filter { _, entry in
            (!favoritesOnly || entry.isFavorite) && (search.isEmpty || entry.title
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(search))
        }.sorted { left, right in
            let a = left.element, b = right.element
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            let order: ComparisonResult
            switch librarySortOrder {
            case .nameAscending: order = a.title.localizedStandardCompare(b.title)
            case .nameDescending: order = b.title.localizedStandardCompare(a.title)
            case .importedNewest: order = Self.compareLibraryDates(a.importedAt, b.importedAt, ascending: false)
            case .importedOldest: order = Self.compareLibraryDates(a.importedAt, b.importedAt, ascending: true)
            case .lastPlayed: order = Self.compareLibraryDates(a.lastPlayedAt, b.lastPlayedAt, ascending: false)
            }
            return order == .orderedSame ? left.offset < right.offset : order == .orderedAscending
        }.map(\.element)
    }

    private static func compareLibraryDates(_ a: Date?, _ b: Date?, ascending: Bool) -> ComparisonResult {
        switch (a, b) {
        case let (a?, b?):
            if a == b { return .orderedSame }
            return (ascending ? a < b : a > b) ? .orderedAscending : .orderedDescending
        case (_?, nil): return .orderedAscending
        case (nil, _?): return .orderedDescending
        case (nil, nil): return .orderedSame
        }
    }

    func toggleFavorite(_ entry: LibraryEntry) {
        guard let index = library.firstIndex(where: { $0.id == entry.id }) else { return }
        var updatedLibrary = library
        updatedLibrary[index].isFavorite.toggle()
        do {
            try saveLibrary(updatedLibrary)
            library = updatedLibrary
        } catch { errorMessage = "收藏保存失败：\(error.localizedDescription)" }
    }

    var songTime: Double {
        if practiceMode == .waitForNotes { return waitEngine.position(at: hostTime) }
        if let leadIn = automaticLeadIn {
            return leadIn.position + (hostTime - leadIn.deadline) * clock.rate
        }
        return clock.position(at: hostTime)
    }
    var isPlaying: Bool { practiceMode == .waitForNotes ? waitEngine.isRunning : automaticLeadIn != nil || clock.isPlaying }
    var playbackRate: Double { clock.rate }
    var isWaiting: Bool { practiceMode == .waitForNotes && waitEngine.isWaiting }
    var waitingPitches: Set<Int> { isWaiting ? waitEngine.requiredPitches : [] }
    var waitingNoteIDs: Set<Int> { isWaiting ? waitEngine.currentGroupNoteIDs : [] }
    var matchedWaitingPitches: Set<Int> { isWaiting ? waitEngine.matchedPitches : [] }
    /// Unlike `waitingNoteIDs`, look-ahead is available before the first target
    /// arrives and immediately after a chord resumes playback.
    var currentTargetNoteIDs: Set<Int> {
        practiceMode == .waitForNotes ? waitEngine.currentGroupNoteIDs : automaticCurrentTargetIDs(at: songTime)
    }
    var nextTargetNoteIDs: Set<Int> {
        practiceMode == .waitForNotes ? waitEngine.nextGroupNoteIDs : automaticNextTargetIDs(at: songTime)
    }
    var currentTargetPitches: Set<Int> {
        practiceMode == .waitForNotes ? waitEngine.requiredPitches : pitches(for: currentTargetNoteIDs)
    }
    var nextTargetPitches: Set<Int> {
        practiceMode == .waitForNotes ? waitEngine.nextRequiredPitches : pitches(for: nextTargetNoteIDs)
    }
    var currentTargetTime: Double? {
        practiceMode == .waitForNotes ? waitEngine.targetTime : currentTargetNoteIDs.compactMap { selectedNotesByID[$0]?.start }.min()
    }
    var nextTargetTime: Double? {
        practiceMode == .waitForNotes ? waitEngine.nextTargetTime : nextTargetNoteIDs.compactMap { selectedNotesByID[$0]?.start }.min()
    }
    var targetPreviewNoteIDs: Set<Int> {
        let time = songTime
        // Wait gating measures its allowance in receiver host seconds; the
        // continuous matcher accepts score seconds. Preview follows each mode's
        // actual policy without silently changing its scoring tolerances.
        let previewWindow = alignmentWindowSeconds * (practiceMode == .waitForNotes ? playbackRate : 1)
        let limit = time + previewWindow
        var ids: Set<Int> = []
        var index = firstPresentationNote(startingAtOrAfter: time)
        while index < presentationNotes.count, presentationNotes[index].start <= limit + 0.000000001 {
            ids.insert(presentationNotes[index].id)
            index += 1
        }
        if practiceMode == .waitForNotes {
            // The first onset anchors a humanized chord; its later members get
            // the same preparation time rather than trickling into the preview.
            if let target = waitEngine.targetTime, target <= limit + 0.000000001 {
                ids.formUnion(waitEngine.currentGroupNoteIDs)
            }
            if let target = waitEngine.nextTargetTime, target <= limit + 0.000000001 {
                ids.formUnion(waitEngine.nextGroupNoteIDs)
            }
            ids.subtract(waitEngine.completedNoteIDs)
            ids.subtract(waitEngine.matchedNoteIDs)
        } else {
            ids.formUnion(automaticCurrentTargetIDs(at: time).filter {
                (selectedNotesByID[$0]?.start ?? -.infinity) >= time - previewWindow - 0.000000001
            })
            ids = ids.filter { !matcher.matchedNoteIDs.contains(canonicalNoteIDs[$0] ?? $0) }
        }
        return ids
    }
    var targetPreviewPitches: Set<Int> { pitches(for: targetPreviewNoteIDs) }
    /// Keyboard guidance in wait mode asks only for the unfinished current
    /// chord. Future score bars and early-input eligibility keep their preview.
    var keyboardTargetNoteIDs: Set<Int> {
        let preview = targetPreviewNoteIDs
        return practiceMode == .waitForNotes ? preview.intersection(waitEngine.currentGroupNoteIDs) : preview
    }
    var inputPulsePitches: Set<Int> { Set(inputPulseUntil.filter { $0.value > hostTime }.keys) }
    /// Brief physical input echo, including ignored/paused/partial-chord input.
    /// A short plateau followed by a fade makes a between-frame staccato visible.
    func inputPulseIntensity(for pitch: Int) -> Double {
        guard let until = inputPulseUntil[pitch] else { return 0 }
        return min(1, max(0, (until - hostTime) / 0.12))
    }
    var activeNotes: Set<Int> { keyState.pressedPitches }
    var correctNotes: Set<Int> { Set(correctUntil.filter { $0.value > hostTime }.keys) }
    var wrongNotes: Set<Int> { Set(wrongUntil.filter { $0.value > hostTime }.keys) }
    var selectedNoteCount: Int { playableNoteCount }
    static var now: Double { ProcessInfo.processInfo.systemUptime }

    init(libraryDirectory: URL? = nil, loadsDemo: Bool = true,
         now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        timeSource = now
        libraryURL = libraryDirectory ?? URL.documentsDirectory.appending(path: "PianoLibrary", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            let index = libraryURL.appending(path: "library.json")
            if FileManager.default.fileExists(atPath: index.path) {
                library = try JSONDecoder().decode([LibraryEntry].self, from: Data(contentsOf: index))
                // Old indexes have no dates. Recover the saved file's metadata
                // when possible; missing files keep their original index order.
                for index in library.indices where library[index].importedAt == nil {
                    let values = try? libraryURL.appending(path: library[index].fileName)
                        .resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
                    library[index].importedAt = values?.creationDate ?? values?.contentModificationDate
                }
            }
        } catch { errorMessage = "无法读取本地曲库：\(error.localizedDescription)" }
        if let data = try? Data(contentsOf: libraryURL.appending(path: "library-preferences.json")),
           let preferences = try? JSONDecoder().decode(LibraryPreferences.self, from: data) {
            librarySortOrder = preferences.sortOrder
            libraryDisplayMode = preferences.displayMode
            libraryColumnCount = preferences.columnCount
        }
        let settingsURL = libraryURL.appending(path: "practice-settings.json")
        var loadedPracticeSettings = false
        if let data = try? Data(contentsOf: settingsURL), let settings = try? JSONDecoder().decode(PracticeSettings.self, from: data) {
            practiceMode = settings.mode
            targetAlignmentMilliseconds = Self.validatedMilliseconds(settings.targetAlignmentMilliseconds, fallback: PracticeSettings.defaultTargetAlignmentMilliseconds)
            automaticHandSplit = settings.automaticHandSplit
            splitPitch = min(108, max(21, settings.splitPitch))
            showFingering = settings.showFingering
            loadedPracticeSettings = true
        }
        var loadedDisplaySettings = false
        if let data = try? Data(contentsOf: libraryURL.appending(path: "display-settings.json")),
           let saved = try? JSONDecoder().decode(PianoDisplaySettings.self, from: data) {
            displaySettings = saved.validated()
            loadedDisplaySettings = true
        }
        restoringPreferences = false
        // Persist decoded migration markers before any user interaction. A later
        // custom choice equal to an old default must never migrate again.
        if loadedPracticeSettings { persistSettings() }
        if loadedDisplaySettings { persistDisplaySettings() }
        bridge.onEvent = { [weak self] event in self?.receive(event) }
        bridge.onReset = { [weak self] in self?.resetInput(); self?.pause() }
        bridge.onMIDIFile = { [weak self] file in
            guard let self else { throw ImportError.unavailable }
            try await self.importMIDIFile(file)
        }
        if loadsDemo { loadDemo() }
    }

    func start() {
        bridge.startBrowsing()
        guard frameTask == nil else { return }
        frameTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updatePractice()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    func loadDemo() {
        guard let url = Bundle.main.url(forResource: "FirstSteps", withExtension: "mid") else {
            errorMessage = "未找到内置示例 MIDI。"
            return
        }
        do { install(try SMFParser.parse(data: Data(contentsOf: url), title: "First Steps · 双手入门"), storageKey: "first-steps-v1") }
        catch { errorMessage = "示例读取失败：\(error.localizedDescription)" }
    }

    func importMIDI(from url: URL) {
        guard !isImporting else { return }
        isImporting = true
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? 0) <= 20_000_000 else { throw ImportError.tooLarge }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 20_000_000 else { throw ImportError.tooLarge }
                    let title = url.deletingPathExtension().lastPathComponent
                    return (try SMFParser.parse(data: data, title: title), data)
                }.value
                try storeImportedSong(result.0, data: result.1)
            } catch { errorMessage = "导入失败：\(error.localizedDescription)" }
            isImporting = false
        }
    }

    func importMIDIFile(_ file: LinkMIDIFile) async throws {
        try Task.checkCancellation()
        guard !isImporting else { throw ImportError.busy }
        guard file.data.count <= 20_000_000 else { throw ImportError.tooLarge }
        isImporting = true
        defer { isImporting = false }
        do {
            let title = String(file.title.filter { character in
                character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
            }.prefix(160))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let song = try await Task.detached(priority: .userInitiated) {
                try SMFParser.parse(data: file.data, title: title.isEmpty ? "Mac MIDI" : title)
            }.value
            try Task.checkCancellation()
            try storeImportedSong(song, data: file.data, activateOnImport: file.activateOnImport, importID: file.importID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            errorMessage = "接收 Mac 曲目失败：\(error.localizedDescription)"
            throw error
        }
    }

    private func storeImportedSong(_ song: PianoSong, data: Data, activateOnImport: Bool = true, importID: UUID? = nil) throws {
        if let importID, let existing = library.first(where: { $0.importID == importID }) {
            let storedURL = libraryURL.appending(path: existing.fileName)
            // The index can survive an accidentally removed MIDI file. A retry
            // carries already validated bytes, so repair that same saved entry
            // before acknowledging it, without replacing the current practice.
            if !FileManager.default.fileExists(atPath: storedURL.path) {
                try data.write(to: storedURL, options: .atomic)
            }
            if activateOnImport {
                let storedSong = try SMFParser.parse(data: Data(contentsOf: storedURL),
                                                    title: existing.title)
                install(storedSong, storageKey: existing.id.uuidString)
            }
            return
        }
        let id = UUID()
        let fileName = "\(id.uuidString).mid"
        let url = libraryURL.appending(path: fileName)
        let entry = LibraryEntry(id: id, title: song.title, fileName: fileName,
                                 noteCount: song.notes.count, duration: song.duration, importID: importID,
                                 importedAt: Date())
        let updatedLibrary = [entry] + library
        try data.write(to: url, options: .atomic)
        do {
            try saveLibrary(updatedLibrary)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        library = updatedLibrary
        if activateOnImport { install(song, storageKey: id.uuidString) }
    }

    @discardableResult func load(_ entry: LibraryEntry) -> Bool {
        do {
            let loadedSong = try SMFParser.parse(data: Data(contentsOf: libraryURL.appending(path: entry.fileName)), title: entry.title)
            install(loadedSong, storageKey: entry.id.uuidString)
            recordLastPlayed(entry.id)
            return true
        } catch {
            errorMessage = "读取曲目失败：\(error.localizedDescription)"
            return false
        }
    }

    private func saveLibrary(_ entries: [LibraryEntry]) throws {
        try JSONEncoder().encode(entries).write(to: libraryURL.appending(path: "library.json"), options: .atomic)
    }

    private func recordLastPlayed(_ id: UUID) {
        guard let index = library.firstIndex(where: { $0.id == id }) else { return }
        var updatedLibrary = library
        updatedLibrary[index].lastPlayedAt = Date()
        do {
            try saveLibrary(updatedLibrary)
            library = updatedLibrary
        } catch { errorMessage = "曲目已载入，但最近打开时间保存失败：\(error.localizedDescription)" }
    }

    private func persistLibraryPreferences() {
        do {
            try JSONEncoder().encode(LibraryPreferences(sortOrder: librarySortOrder,
                                                       displayMode: libraryDisplayMode, columnCount: libraryColumnCount))
                .write(to: libraryURL.appending(path: "library-preferences.json"), options: .atomic)
        } catch { errorMessage = "曲库显示偏好保存失败：\(error.localizedDescription)" }
    }

    func install(_ newSong: PianoSong, storageKey: String? = nil) {
        pause()
        cancelFingering()
        clock.seek(to: 0, at: hostTime)
        song = newSong
        currentSongKey = storageKey
        songRevision += 1
        enabledTrackIDs = Set(newSong.tracks.map(\.id))
        trackHands = HandAssignment.initialTrackAssignments(song: newSong)
        fingerOverrides.removeAll()
        generatedFingers.removeAll()
        if let url = annotationURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(SongPracticeAnnotations.self, from: data) {
            let tracks = Set(newSong.tracks.map(\.id))
            trackHands = saved.trackHands.filter { tracks.contains($0.key) }
            let notes = Set(newSong.notes.map(\.id))
            fingerOverrides = saved.fingerOverrides.filter { notes.contains($0.key) && (1...5).contains($0.value) }
        }
        rebuildHands(preserveOverrides: true)
        rebuildMatcher(startingAt: 0)
        resetInput()
        uiTime = 0
    }

    func setTrack(_ id: Int, enabled: Bool) {
        pause()
        if enabled { enabledTrackIDs.insert(id) } else { enabledTrackIDs.remove(id) }
        rebuildMatcher()
    }

    func play() {
        guard !isPlaying, let song, selectedNoteCount > 0 else { return }
        guard !calibration.isFingerCalibrationActive, !calibration.hasFingerCalibrationFirstPoint else {
            errorMessage = "请先完成琴位取点，或取消取点后再开始练习。"
            return
        }
        let hasPendingWaitTarget = practiceMode == .waitForNotes && waitEngine.targetTime != nil
        if songTime >= song.duration && !hasPendingWaitTarget { seek(to: 0) }
        if isImmersiveActive && !calibration.isTracked {
            errorMessage = "琴位尚未完成定位。请先完成校准，或等待空间锚点恢复。"
            return
        }
        if practiceMode == .waitForNotes { waitEngine.play(at: hostTime) }
        else { beginAutomaticLeadIn(at: hostTime) }
        if practiceMode == .waitForNotes { scoringEpochHostTime = hostTime }
    }

    func pause() {
        performanceGrade.advance(to: timingHostTime)
        performanceGrade.interrupt()
        finishAutomaticLeadInIfNeeded(at: hostTime)
        automaticLeadIn = nil
        preparationCountdown = 0
        clock.pause(at: hostTime)
        waitEngine.pause(at: hostTime)
        invalidatePendingFeedback()
        uiTime = min(songTime, song?.duration ?? 0)
    }
    func restart() { pause(); seek(to: 0) }
    func seek(to value: Double) {
        let wasAutomaticPlaying = practiceMode == .automatic && isPlaying
        automaticLeadIn = nil
        preparationCountdown = 0
        let position = min(max(0, value), song?.duration ?? 0)
        clock.seek(to: position, at: hostTime)
        waitEngine.seek(to: position, at: hostTime)
        scoringEpochHostTime = hostTime
        matcher.reset(startingAt: position)
        resetScore()
        correctUntil.removeAll()
        wrongUntil.removeAll()
        inputPulseUntil.removeAll()
        heldNoteIDsByPitch.removeAll()
        heldCorrectNotes.removeAll()
        heldWrongNotes.removeAll()
        completedHeldNotes.removeAll()
        uiTime = position
        if wasAutomaticPlaying {
            clock.pause(at: hostTime)
            beginAutomaticLeadIn(at: hostTime)
        }
    }

    func setRate(_ value: Double) {
        performanceGrade.advance(to: timingHostTime)
        performanceGrade.interrupt()
        finishAutomaticLeadInIfNeeded(at: hostTime)
        clock.setRate(value, at: hostTime)
        waitEngine.setRate(value, at: hostTime)
        invalidatePendingFeedback()
        scoringEpochHostTime = hostTime
    }

    func setPracticeMode(_ mode: PracticeMode) {
        guard mode != practiceMode else { return }
        finishAutomaticLeadInIfNeeded(at: hostTime)
        let position = automaticLeadIn?.position ?? songTime
        pause()
        practiceMode = mode
        seek(to: position)
        resetInput()
        persistSettings()
    }

    func spatialTrackingDidChange(_ isTracked: Bool) {
        if !isTracked { pause() }
    }

    func resetInput() {
        performanceGrade.interrupt()
        keyState.reset()
        waitEngine.resetInput(at: hostTime)
        correctUntil.removeAll()
        wrongUntil.removeAll()
        inputPulseUntil.removeAll()
        heldNoteIDsByPitch.removeAll()
        heldCorrectNotes.removeAll()
        heldWrongNotes.removeAll()
        completedHeldNotes.removeAll()
        pedalDown = false
    }

    func receive(_ event: LinkMIDIEvent) {
        guard inputChannel < 0 || event.channel == inputChannel else { return }
        finishAutomaticLeadInIfNeeded(at: hostTime)
        let pressedBeforeInput = activeNotes
        defer {
            let released = pressedBeforeInput.subtracting(activeNotes)
            for pitch in released {
                if event.kind == .noteOff || (event.kind == .noteOn && event.velocity == 0) {
                    performanceGrade.noteOff(pitch: pitch, at: event.timestamp + (practiceMode == .automatic ? inputOffsetMilliseconds / 1000 : 0))
                } else {
                    performanceGrade.cancelHeld(pitch: pitch)
                }
            }
            if practiceMode == .waitForNotes {
                performanceGrade.retainPending(validNoteIDs: waitEngine.completedNoteIDs.union(waitEngine.matchedNoteIDs))
            }
            // A pitch remains physically held until its last MIDI channel releases it.
            heldCorrectNotes.formIntersection(activeNotes)
            heldWrongNotes.formIntersection(activeNotes)
            completedHeldNotes.formIntersection(activeNotes)
            heldNoteIDsByPitch = heldNoteIDsByPitch.filter { activeNotes.contains($0.key) }
        }
        switch event.kind {
        case .noteOn:
            guard event.velocity > 0 else {
                keyState.noteOff(pitch: event.note, channel: event.channel)
                if let result = waitEngine.noteOff(pitch: event.note, timestamp: event.timestamp,
                                                    receivedAt: hostTime, pressedPitches: activeNotes) {
                    applyWait(result)
                }
                return
            }
            let wasHeld = activeNotes.contains(event.note)
            // Echo the raw physical event independently of score acceptance.
            // NoteOff does not remove this minimum visible pulse.
            if (0...127).contains(event.note) { inputPulseUntil[event.note] = hostTime + 0.18 }
            if !wasHeld {
                heldNoteIDsByPitch.removeValue(forKey: event.note)
                heldCorrectNotes.remove(event.note)
                heldWrongNotes.remove(event.note)
                completedHeldNotes.remove(event.note)
                correctUntil.removeValue(forKey: event.note)
                wrongUntil.removeValue(forKey: event.note)
            }
            keyState.noteOn(pitch: event.note, velocity: event.velocity, channel: event.channel)
            var label = "按下"
            if practiceMode == .waitForNotes {
                let result = waitEngine.noteOn(pitch: event.note, timestamp: event.timestamp,
                                               receivedAt: hostTime, pressedPitches: activeNotes)
                label = applyWait(result, inputPitch: event.note)
                if !wasHeld {
                    assignHeldWaitNoteIDs(pitch: event.note, result: result)
                    if result.disposition == .accepted || result.disposition == .completed,
                       let target = result.targetHostTime, let groupTime = result.groupTime,
                       let note = waitEngine.noteIDs(inGroupAt: groupTime, pitch: event.note)
                        .compactMap({ selectedNotesByID[$0] })
                        .min(by: { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }) {
                        performanceGrade.noteOn(id: note.id, pitch: note.pitch, performedAt: event.timestamp,
                                                targetAt: target + (note.start - groupTime) / playbackRate,
                                                duration: note.duration / playbackRate,
                                                committed: waitEngine.completedNoteIDs.contains(note.id))
                    }
                }
            } else if !wasHeld && automaticLeadIn == nil && isPlaying && event.timestamp >= scoringEpochHostTime {
                let eventTime = event.timestamp + inputOffsetMilliseconds / 1000
                let result = matcher.noteOn(pitch: event.note, velocity: event.velocity,
                                           channel: event.channel, songTime: clock.position(at: eventTime))
                label = apply(result)
                if !wasHeld, let id = result.noteID, result.isMatched {
                    heldNoteIDsByPitch[event.note] = aliasesByCanonicalNoteID[id] ?? [id]
                    if let note = selectedNotesByID[id] {
                        performanceGrade.noteOn(id: id, pitch: note.pitch, performedAt: eventTime,
                                                targetAt: hostTime + (note.start - clock.position(at: hostTime)) / playbackRate,
                                                duration: note.duration / playbackRate, committed: true)
                    }
                }
            }
            recentInputs.insert(RecentInput(pitch: event.note, velocity: event.velocity, channel: event.channel, label: label), at: 0)
            recentInputs = Array(recentInputs.prefix(12))
        case .noteOff:
            keyState.noteOff(pitch: event.note, channel: event.channel)
            if let result = waitEngine.noteOff(pitch: event.note, timestamp: event.timestamp,
                                                receivedAt: hostTime, pressedPitches: activeNotes) {
                applyWait(result)
            }
        case .controlChange:
            keyState.controlChange(controller: event.controller, value: event.value, channel: event.channel)
            pedalDown = (0..<16).contains { keyState.isSustainDown(channel: $0) }
            if event.controller == 120 || (123...127).contains(event.controller) {
                waitEngine.resetInput(at: hostTime, pressedPitches: activeNotes)
                invalidatePendingFeedback()
            }
        case .allNotesOff:
            // Channel-mode CC120/123 must respect filtering, other channels and sustain.
            keyState.controlChange(controller: event.controller == 120 ? 120 : 123,
                                   value: event.value, channel: event.channel)
            pedalDown = (0..<16).contains { keyState.isSustainDown(channel: $0) }
            waitEngine.resetInput(at: hostTime, pressedPitches: activeNotes)
            invalidatePendingFeedback()
        }
    }

    @discardableResult private func applyWait(_ result: WaitInputResult, inputPitch: Int? = nil) -> String {
        // One input can settle an earlier target and independently match the next one.
        hitCount += result.completedNotes.count
        performanceGrade.commit(noteIDs: result.completedNoteIDs)
        performanceGrade.retainPending(validNoteIDs: waitEngine.completedNoteIDs.union(waitEngine.matchedNoteIDs))
        for note in result.completedNotes { markCorrect(note.pitch) }
        if !result.completedNotes.isEmpty { lastTimingMilliseconds = nil }
        switch result.disposition {
        case .completed:
            return "正确"
        case .accepted:
            if let inputPitch { markCorrect(inputPitch, flashes: false) }
            return "已就位"
        case .wrong:
            wrongCount += 1
            if let inputPitch { markWrong(inputPitch) }
            return "错音"
        case .ignored: return "按下"
        }
    }

    @discardableResult private func apply(_ result: MatchResult) -> String {
        switch result.judgement {
        case .hit, .early, .late:
            if result.recoveredMiss { missedCount = max(0, missedCount - 1) }
            hitCount += 1
            markCorrect(result.pitch)
            lastTimingMilliseconds = result.timingError.map { $0 * 1000 }
            switch result.judgement {
            case .early: return "稍早"
            case .late: return "稍晚"
            default: return "正确"
            }
        case .wrong:
            wrongCount += 1
            markWrong(result.pitch)
            return "错音"
        case .missed:
            missedCount += 1
            return "漏音"
        case .ignored:
            return "忽略"
        }
    }

    private func markCorrect(_ pitch: Int, flashes: Bool = true) {
        wrongUntil.removeValue(forKey: pitch)
        heldWrongNotes.remove(pitch)
        if activeNotes.contains(pitch) {
            heldCorrectNotes.insert(pitch)
            if flashes { completedHeldNotes.insert(pitch) }
        }
        if flashes { correctUntil[pitch] = hostTime + 0.35 }
    }

    private func markWrong(_ pitch: Int) {
        correctUntil.removeValue(forKey: pitch)
        heldCorrectNotes.remove(pitch)
        completedHeldNotes.remove(pitch)
        if activeNotes.contains(pitch) { heldWrongNotes.insert(pitch) }
        wrongUntil[pitch] = hostTime + 0.5
    }

    private func invalidatePendingFeedback() {
        // Completed held notes stay green, while candidates discarded by a
        // clock/input reset must no longer appear ready to pass the next gate.
        heldCorrectNotes.formIntersection(completedHeldNotes)
        let completedIDs: Set<Int>
        if practiceMode == .waitForNotes { completedIDs = waitEngine.completedNoteIDs }
        else {
            completedIDs = matcher.matchedNoteIDs.reduce(into: []) { ids, canonicalID in
                ids.formUnion(aliasesByCanonicalNoteID[canonicalID] ?? [canonicalID])
            }
        }
        heldNoteIDsByPitch = heldNoteIDsByPitch.compactMapValues { ids in
            let retained = ids.intersection(completedIDs)
            return retained.isEmpty ? nil : retained
        }
    }

    func hand(for note: PianoNote) -> PianoHand { noteHands[note.id] ?? .unassigned }

    func notePresentation(for note: PianoNote) -> PianoNotePresentation {
        guard enabledTrackIDs.contains(note.track), selectedNotesByID[note.id] != nil else {
            return PianoNotePresentation(role: .upcoming, progress: .unplayed, isHeld: false,
                                         needsRestrike: false, isPendingEarly: false)
        }
        let role: PianoNoteRole
        let progress: PianoNoteProgress
        let isPendingEarly: Bool
        if practiceMode == .waitForNotes {
            let currentIDs = waitEngine.currentGroupNoteIDs
            role = currentIDs.contains(note.id) ? .current
                : waitEngine.nextGroupNoteIDs.contains(note.id) ? .next : .upcoming
            progress = waitEngine.completedNoteIDs.contains(note.id) ? .completed
                : waitEngine.matchedNoteIDs.contains(note.id) ? .accepted : .unplayed
            isPendingEarly = progress == .accepted && !currentIDs.contains(note.id)
        } else {
            let time = songTime
            role = note.start <= time && note.end > time ? .current
                : automaticNextTargetIDs(at: time).contains(note.id) ? .next : .upcoming
            let canonicalID = canonicalNoteIDs[note.id] ?? note.id
            progress = matcher.matchedNoteIDs.contains(canonicalID) ? .completed : .unplayed
            isPendingEarly = false
        }
        let isHeld = activeNotes.contains(note.pitch) && heldNoteIDsByPitch[note.pitch]?.contains(note.id) == true
        let onsetStillMatchable = practiceMode == .waitForNotes
            || note.start >= songTime - alignmentWindowSeconds - 0.000000001
        let needsRestrike = role != .upcoming && progress == .unplayed
            && activeNotes.contains(note.pitch) && onsetStillMatchable
        return PianoNotePresentation(role: role, progress: progress, isHeld: isHeld,
                                     needsRestrike: needsRestrike, isPendingEarly: isPendingEarly)
    }

    func noteFeedback(for note: PianoNote) -> PianoNoteFeedback {
        notePresentation(for: note).feedback
    }

    private func assignHeldWaitNoteIDs(pitch: Int, result: WaitInputResult) {
        if (result.disposition == .accepted || result.disposition == .completed), let time = result.groupTime {
            let ids = waitEngine.noteIDs(inGroupAt: time, pitch: pitch)
            if !ids.isEmpty { heldNoteIDsByPitch[pitch] = ids; return }
        }
        // A replay of an already accepted current arpeggio can show its exact
        // hold, but an ignored raw/too-early press has no score-note ownership.
        let ids = waitEngine.currentGroupNoteIDs.intersection(waitEngine.matchedNoteIDs)
            .filter { selectedNotesByID[$0]?.pitch == pitch }
        if !ids.isEmpty { heldNoteIDsByPitch[pitch] = ids }
    }

    private func pitches(for ids: Set<Int>) -> Set<Int> {
        Set(ids.compactMap { selectedNotesByID[$0]?.pitch })
    }

    private func firstPresentationNote(startingAtOrAfter time: Double, strictlyAfter: Bool = false) -> Int {
        var low = 0
        var high = presentationNotes.count
        while low < high {
            let middle = (low + high) / 2
            let before = strictlyAfter ? presentationNotes[middle].start <= time : presentationNotes[middle].start < time
            if before { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func automaticCurrentTargetIDs(at time: Double) -> Set<Int> {
        var low = 0
        var high = presentationMaximumEnds.count
        while low < high {
            let middle = (low + high) / 2
            if presentationMaximumEnds[middle] <= time { low = middle + 1 } else { high = middle }
        }
        var ids: Set<Int> = []
        while low < presentationNotes.count, presentationNotes[low].start <= time {
            let note = presentationNotes[low]
            if note.end > time { ids.insert(note.id) }
            low += 1
        }
        return ids
    }

    private func automaticNextTargetIDs(at time: Double) -> Set<Int> {
        var index = firstPresentationNote(startingAtOrAfter: time, strictlyAfter: true)
        guard index < presentationNotes.count else { return [] }
        let start = presentationNotes[index].start
        var ids: Set<Int> = []
        while index < presentationNotes.count, presentationNotes[index].start == start {
            ids.insert(presentationNotes[index].id)
            index += 1
        }
        return ids
    }

    func finger(for note: PianoNote) -> Int? {
        guard showFingering else { return nil }
        return fingerOverrides[note.id] ?? generatedFingers[note.id]
    }

    func setHand(_ hand: PianoHand?, forTrack trackID: Int) {
        guard song?.tracks.contains(where: { $0.id == trackID }) == true else { return }
        trackHands[trackID] = hand
        rebuildHands()
    }

    func setFinger(_ finger: Int?, for noteID: Int) {
        guard song?.notes.contains(where: { $0.id == noteID }) == true,
              finger == nil || (1...5).contains(finger!) else { return }
        fingerOverrides[noteID] = finger
        annotationRevision += 1
        persistAnnotations()
    }

    func generateFingering() {
        guard let notes = song?.notes, !notes.isEmpty else { return }
        cancelFingering()
        let id = UUID()
        generationID = id
        let hands = noteHands
        isGeneratingFingering = true
        let work = Task.detached(priority: .userInitiated) {
            FingeringGenerator.generate(notes: notes, hands: hands)
        }
        fingeringTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled, self.generationID == id else { return }
            self.generatedFingers = result.fingers
            self.unsupportedFingeringCount = result.unsupportedNoteIDs.count
            self.isGeneratingFingering = false
            self.annotationRevision += 1
            self.fingeringTask = nil
        }
    }

    private func cancelFingering() {
        generationID = UUID()
        fingeringTask?.cancel()
        fingeringTask = nil
        isGeneratingFingering = false
    }

    private func rebuildHands(preserveOverrides: Bool = false) {
        guard !restoringPreferences else { return }
        cancelFingering()
        let resolved = HandAssignment.resolve(notes: song?.notes ?? [], trackHands: trackHands,
                                              automaticSplit: automaticHandSplit, splitPitch: min(108, max(21, splitPitch)))
        if !preserveOverrides {
            fingerOverrides = fingerOverrides.filter { noteHands[$0.key] == resolved[$0.key] }
        }
        noteHands = resolved
        generatedFingers.removeAll()
        unsupportedFingeringCount = 0
        annotationRevision += 1
        persistAnnotations()
        if showFingering { generateFingering() }
    }

    private var annotationURL: URL? {
        currentSongKey.map { libraryURL.appending(path: "Annotations", directoryHint: .isDirectory).appending(path: "\($0).json") }
    }

    private func persistAnnotations() {
        guard let url = annotationURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(SongPracticeAnnotations(trackHands: trackHands, fingerOverrides: fingerOverrides))
                .write(to: url, options: .atomic)
        } catch { errorMessage = "演奏手和指法设置保存失败：\(error.localizedDescription)" }
    }

    private func persistSettings() {
        guard !restoringPreferences else { return }
        do {
            let settings = PracticeSettings(mode: practiceMode,
                                            automaticHandSplit: automaticHandSplit, splitPitch: min(108, max(21, splitPitch)),
                                            showFingering: showFingering,
                                            targetAlignmentMilliseconds: Self.validatedMilliseconds(targetAlignmentMilliseconds, fallback: PracticeSettings.defaultTargetAlignmentMilliseconds))
            try JSONEncoder().encode(settings).write(to: libraryURL.appending(path: "practice-settings.json"), options: .atomic)
        } catch { errorMessage = "练习设置保存失败：\(error.localizedDescription)" }
    }

    private func persistDisplaySettings() {
        do {
            try JSONEncoder().encode(displaySettings.validated())
                .write(to: libraryURL.appending(path: "display-settings.json"), options: .atomic)
        } catch { errorMessage = "显示设置保存失败：\(error.localizedDescription)" }
    }

    private func rebuildMatcher(startingAt position: Double? = nil) {
        let position = position ?? songTime
        // Multiple MIDI tracks may double the same physical key at exactly the same onset.
        // One key press should satisfy that target, rather than require two simultaneous presses.
        struct Onset: Hashable { let pitch: Int; let start: Double }
        let selected = (song?.notes ?? []).filter {
            enabledTrackIDs.contains($0.track) && (minMIDINote..<(minMIDINote + keyCount)).contains($0.pitch)
        }
        presentationNotes = selected.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
        selectedNotesByID = selected.reduce(into: [:]) { $0[$1.id] = $1 }
        var maximumEnd = 0.0
        presentationMaximumEnds = presentationNotes.map { note in
            maximumEnd = max(maximumEnd, note.end)
            return maximumEnd
        }
        var canonicalByOnset: [Onset: Int] = [:]
        canonicalNoteIDs.removeAll(keepingCapacity: true)
        aliasesByCanonicalNoteID.removeAll(keepingCapacity: true)
        let playable = selected.filter { note in
            let onset = Onset(pitch: note.pitch, start: note.start)
            if let existing = canonicalByOnset[onset] {
                canonicalNoteIDs[note.id] = existing
                aliasesByCanonicalNoteID[existing, default: []].insert(note.id)
                return false
            }
            canonicalByOnset[onset] = note.id
            canonicalNoteIDs[note.id] = note.id
            aliasesByCanonicalNoteID[note.id, default: []].insert(note.id)
            return true
        }
        playableNoteCount = playable.count
        matcher = PerformanceMatcher(notes: playable, earlyTolerance: alignmentWindowSeconds, lateTolerance: alignmentWindowSeconds)
        matcher.reset(startingAt: position)
        waitEngine = WaitModeEngine(notes: selected, duration: song?.duration ?? 0,
                                    earlyInputWindow: alignmentWindowSeconds,
                                    inputTolerance: .relaxed, now: hostTime)
        waitEngine.setRate(clock.rate, at: hostTime)
        waitEngine.seek(to: position, at: hostTime)
        waitEngine.resetInput(at: hostTime, pressedPitches: activeNotes)
        resetScore()
    }

    private func resetScore() {
        performanceGrade = PerformanceGrade()
        hitCount = 0; wrongCount = 0; missedCount = 0
        lastTimingMilliseconds = nil
        heldCorrectNotes.removeAll()
        heldWrongNotes.removeAll()
        completedHeldNotes.removeAll()
        heldNoteIDsByPitch.removeAll()
    }

    func updatePractice() {
        performanceGrade.advance(to: timingHostTime)
        if practiceMode == .waitForNotes {
            if let result = waitEngine.update(at: hostTime) { applyWait(result) }
            performanceGrade.retainPending(validNoteIDs: waitEngine.completedNoteIDs.union(waitEngine.matchedNoteIDs))
            uiTime = songTime
            return
        }
        finishAutomaticLeadInIfNeeded(at: hostTime)
        if let leadIn = automaticLeadIn {
            preparationCountdown = max(1, Int(ceil(leadIn.deadline - hostTime)))
            uiTime = leadIn.position
            return
        }
        uiTime = min(songTime, song?.duration ?? 0)
        guard isPlaying, let song else { return }
        for result in matcher.advance(to: songTime) { apply(result) }
        // Accept late network delivery for the final note before settling the score.
        if songTime >= song.duration + max(0.3, alignmentWindowSeconds) + 1.5 * clock.rate {
            clock.pause(at: hostTime)
            clock.seek(to: song.duration, at: hostTime)
            uiTime = song.duration
        }
    }

    private func beginAutomaticLeadIn(at now: Double) {
        let deadline = now + 3
        automaticLeadIn = AutomaticLeadIn(position: clock.position(at: now), deadline: deadline)
        preparationCountdown = 3
        scoringEpochHostTime = deadline
    }

    private func finishAutomaticLeadInIfNeeded(at now: Double) {
        guard let leadIn = automaticLeadIn, now >= leadIn.deadline else { return }
        automaticLeadIn = nil
        preparationCountdown = 0
        // Anchor at the exact deadline so a delayed frame does not lose time.
        clock.seek(to: leadIn.position, at: leadIn.deadline)
        clock.play(at: leadIn.deadline)
        scoringEpochHostTime = leadIn.deadline
    }

    private static func validatedMilliseconds(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(2000, max(50, value)) : fallback
    }

    static func noteName(_ pitch: Int) -> String {
        let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
        return "\(names[(pitch % 12 + 12) % 12])\(pitch / 12 - 1)"
    }

    static func timeLabel(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(min(100_000_000, max(0, seconds))) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

private enum ImportError: LocalizedError {
    case tooLarge, busy, unavailable
    var errorDescription: String? {
        switch self {
        case .tooLarge: "MIDI 文件超过 20 MB，请选择较小的文件。"
        case .busy: "正在导入另一首 MIDI，请稍后重试。"
        case .unavailable: "练习会话已关闭，请重新连接。"
        }
    }
}
