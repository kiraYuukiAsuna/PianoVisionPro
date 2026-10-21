import Darwin
import Foundation
import Observation
import PianoLink

struct MIDIBatchItem: Identifiable, Sendable {
    enum State: String, Sendable {
        case pending, reading, sending, imported, failed, cancelled

        var label: String {
            switch self {
            case .pending: "待发送"
            case .reading: "正在读取"
            case .sending: "等待头显确认"
            case .imported: "已导入"
            case .failed: "失败，可重试"
            case .cancelled: "已取消，可继续"
            }
        }
        var isFailure: Bool { self == .failed }
    }

    let id: UUID
    let relativePath: String
    var byteCount: Int
    var state: State
    var errorMessage: String?
    fileprivate let url: URL
    fileprivate let snapshot: MIDIFileSnapshot?
}

/// Metadata only: file contents are loaded one song at a time, immediately before sending.
@MainActor @Observable
final class MIDIBatchImportModel {
    private(set) var items: [MIDIBatchItem] = []
    private(set) var status = "选择 MIDI 文件或文件夹，连接头显后手动发送。"
    private(set) var isScanning = false
    private(set) var isSending = false

    var importedCount: Int { items.filter { $0.state == .imported }.count }
    var failedCount: Int { items.filter { $0.state.isFailure }.count }
    var pendingCount: Int { items.count - importedCount - failedCount }
    var canSend: Bool { !isScanning && !isSending && selection != nil && items.contains { $0.state != .imported } }

    func canSend(to receiverID: UUID) -> Bool {
        guard !isScanning, !isSending, selection != nil, !items.isEmpty else { return false }
        return canSend || (lastReceiverID != nil && lastReceiverID != receiverID)
    }

    @ObservationIgnored private let sender: @MainActor (LinkMIDIFile, UUID) async throws -> Void
    @ObservationIgnored private var selection: MIDISelection?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    private var lastReceiverID: UUID?

    init(sender: @escaping @MainActor (LinkMIDIFile, UUID) async throws -> Void) { self.sender = sender }

    func selectFile(_ url: URL) { select(url, folder: false) }
    func selectFolder(_ url: URL) { select(url, folder: true) }

    func selectionFailed(_ error: any Error) {
        guard (error as? CocoaError)?.code != .userCancelled else { return }
        guard !isSending else { return }
        scanTask?.cancel()
        scanTask = nil
        selection = nil
        lastReceiverID = nil
        items.removeAll()
        isScanning = false
        status = "选择失败：\(error.localizedDescription)"
    }

    func send(to receiverID: UUID) {
        guard canSend(to: receiverID), let selected = selection else { return }
        let changedReceiver = lastReceiverID != nil && lastReceiverID != receiverID
        if changedReceiver {
            for index in items.indices where items[index].state == .imported {
                items[index].state = .pending
                items[index].errorMessage = nil
            }
        }
        lastReceiverID = receiverID
        let pendingIDs = items.filter { $0.state != .imported }.map(\.id)
        isSending = true
        status = changedReceiver ? "接收连接已变化，将重新确认全部曲目…" : "正在发送到选定头显…"
        sendTask = Task { @MainActor [weak self, selected] in
            guard let self else { return }
            defer {
                if self.selection?.id == selected.id {
                    self.isSending = false
                    self.sendTask = nil
                }
            }
            var stoppedForConnection = false
            var cancelled = false
            for id in pendingIDs {
                guard let index = self.items.firstIndex(where: { $0.id == id }) else { continue }
                do {
                    try Task.checkCancellation()
                    self.items[index].state = .reading
                    self.items[index].errorMessage = nil
                    self.status = "正在读取：\(self.items[index].relativePath)"
                    let item = self.items[index]
                    let read = Task.detached(priority: .userInitiated) { [selected, item] in
                        try Self.read(item, selection: selected)
                    }
                    let file = try await withTaskCancellationHandler {
                        try await read.value
                    } onCancel: { read.cancel() }
                    try Task.checkCancellation()
                    guard self.selection?.id == selected.id else { return }
                    self.items[index].byteCount = file.data.count
                    self.items[index].state = .sending
                    self.status = "正在发送：\(item.relativePath)"
                    try await self.sender(file, receiverID)
                    guard self.selection?.id == selected.id else { return }
                    // A normal sender return is a durable receipt. Keep that
                    // success even if cancellation races the continuation.
                    self.items[index].state = .imported
                    self.items[index].errorMessage = nil
                } catch {
                    guard self.selection?.id == selected.id else { return }
                    if error is CancellationError || Task.isCancelled {
                        self.items[index].state = .cancelled
                        self.items[index].errorMessage = nil
                        cancelled = true
                        break
                    }
                    self.items[index].state = .failed
                    self.items[index].errorMessage = error.localizedDescription
                    if Self.isConnectionFailure(error) { stoppedForConnection = true; break }
                }
            }
            if Task.isCancelled { cancelled = true }
            if self.selection?.id != selected.id { return }
            if cancelled {
                self.status = "已取消；已导入 \(self.importedCount) 首，其余文件可继续发送。"
            } else if stoppedForConnection {
                self.status = "传输连接不可用；已导入 \(self.importedCount) 首，重新连接后可继续发送其余文件。"
            } else {
                self.status = "发送结束：已导入 \(self.importedCount) 首，失败 \(self.failedCount) 首。"
            }
        }
    }

    func cancel() {
        if isScanning { scanTask?.cancel(); status = "正在取消扫描…" }
        if isSending { sendTask?.cancel(); status = "正在取消发送…" }
    }

    func stop() {
        scanTask?.cancel(); scanTask = nil
        sendTask?.cancel(); sendTask = nil
        // Tasks own their own lease until detached I/O and the sender actually
        // return. Releasing the model's lease cannot revoke in-flight access.
        selection = nil
        lastReceiverID = nil
        items.removeAll()
        isScanning = false
        isSending = false
        status = "已停止，请重新选择文件或文件夹。"
    }

    private func select(_ url: URL, folder: Bool) {
        guard !isSending else { status = "请先取消当前发送，再选择其他文件。"; return }
        scanTask?.cancel()
        let selected = MIDISelection(url: url, folder: folder)
        selection = selected
        lastReceiverID = nil
        items.removeAll()
        isScanning = true
        status = folder ? "正在扫描文件夹…" : "正在检查 MIDI 文件…"
        scanTask = Task { @MainActor [weak self, selected] in
            let scan = Task.detached(priority: .userInitiated) { [selected] in try Self.scan(selected) }
            do {
                let result = try await withTaskCancellationHandler {
                    try await scan.value
                } onCancel: { scan.cancel() }
                try Task.checkCancellation()
                guard let self, self.selection?.id == selected.id else { return }
                self.items = result.items
                if result.items.isEmpty {
                    self.status = result.warning ?? "文件夹中没有找到 .mid 或 .midi 文件。"
                } else {
                    self.status = "已选择 \(result.items.count) 首；连接头显后手动发送。"
                    if let warning = result.warning { self.status += " \(warning)" }
                }
            } catch {
                guard let self, self.selection?.id == selected.id else { return }
                if error is CancellationError || Task.isCancelled { self.status = "扫描已取消，请重新选择文件夹。" }
                else { self.status = "选择失败：\(error.localizedDescription)" }
            }
            guard let self, self.selection?.id == selected.id else { return }
            self.isScanning = false
            self.scanTask = nil
        }
    }

    private nonisolated static func isConnectionFailure(_ error: any Error) -> Bool {
        guard let error = error as? MIDIFileTransferError else { return false }
        return switch error {
        case .disconnected, .timedOut, .busy, .invalidTransfer: true
        case .invalidSize, .rejected: false
        }
    }

    private struct ScanResult: Sendable { let items: [MIDIBatchItem]; let warning: String? }

    private nonisolated static func scan(_ selection: MIDISelection) throws -> ScanResult {
        try withExtendedLifetime(selection.lease) {
            try Task.checkCancellation()
            let root = selection.url
            let rootInfo = try MIDIFileSnapshot.information(at: root)
            guard !rootInfo.isSymlink else { throw MIDIBatchError.symbolicLink }
            if !selection.folder {
                guard ["mid", "midi"].contains(root.pathExtension.lowercased()), rootInfo.isRegular else {
                    throw MIDIBatchError.notMIDIFile
                }
                return ScanResult(items: [makeItem(url: root, relativePath: root.lastPathComponent, info: rootInfo)], warning: nil)
            }
            guard rootInfo.isDirectory else { throw MIDIBatchError.notDirectory }
            let keys: [URLResourceKey] = [.isHiddenKey, .isPackageKey, .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]
            var skippedErrors = 0
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in
                    skippedErrors += 1
                    return true
                }) else { throw MIDIBatchError.unreadableDirectory }
            var items: [MIDIBatchItem] = []
            for case let url as URL in enumerator {
                try Task.checkCancellation()
                do {
                    let values = try url.resourceValues(forKeys: Set(keys))
                    if values.isSymbolicLink == true || values.isHidden == true || values.isPackage == true || url.lastPathComponent.hasPrefix(".") {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard values.isRegularFile == true, ["mid", "midi"].contains(url.pathExtension.lowercased()) else { continue }
                    let relative = try relativePath(url, inside: root)
                    let info = try MIDIFileSnapshot.information(at: url)
                    guard info.isRegular, !info.isSymlink else { continue }
                    items.append(makeItem(url: url, relativePath: relative, info: info))
                } catch { skippedErrors += 1 }
            }
            items.sort {
                let left = $0.relativePath.lowercased(), right = $1.relativePath.lowercased()
                return left == right ? $0.relativePath < $1.relativePath : left < right
            }
            let warning = skippedErrors > 0 ? "有 \(skippedErrors) 个路径无法读取，已跳过。" : nil
            return ScanResult(items: items, warning: warning)
        }
    }

    private nonisolated static func makeItem(url: URL, relativePath: String, info: MIDIFileSnapshot) -> MIDIBatchItem {
        let sizeValid = info.byteCount > 0 && info.byteCount <= LinkMIDIFile.maximumByteCount
        return MIDIBatchItem(id: UUID(), relativePath: relativePath, byteCount: info.byteCount,
                             state: sizeValid ? .pending : .failed,
                             errorMessage: sizeValid ? nil : MIDIFileTransferError.invalidSize.localizedDescription,
                             url: url, snapshot: info)
    }

    private nonisolated static func relativePath(_ url: URL, inside root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { throw MIDIBatchError.symbolicLink }
        return String(path.dropFirst(prefix.count))
    }

    private nonisolated static func read(_ item: MIDIBatchItem, selection: MIDISelection) throws -> LinkMIDIFile {
        try withExtendedLifetime(selection.lease) {
            try Task.checkCancellation()
            if selection.folder {
                _ = try relativePath(item.url, inside: selection.url)
                var directory = item.url.deletingLastPathComponent().standardizedFileURL
                while true {
                    let info = try MIDIFileSnapshot.information(at: directory)
                    guard info.isDirectory, !info.isSymlink else { throw MIDIBatchError.symbolicLink }
                    if directory == selection.url { break }
                    _ = try relativePath(directory, inside: selection.url)
                    directory.deleteLastPathComponent()
                }
            }
            // O_NOFOLLOW rejects a file replaced with a symbolic link after
            // selection; O_NONBLOCK also prevents a replacement FIFO hanging I/O.
            let descriptor = item.url.withUnsafeFileSystemRepresentation {
                Darwin.open($0!, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            let before = try MIDIFileSnapshot.information(descriptor: descriptor)
            guard before.isRegular, let original = item.snapshot, before == original else { throw MIDIBatchError.sourceChanged }
            guard before.byteCount > 0, before.byteCount <= LinkMIDIFile.maximumByteCount else { throw MIDIFileTransferError.invalidSize }
            var data = Data()
            data.reserveCapacity(before.byteCount)
            while data.count <= LinkMIDIFile.maximumByteCount {
                try Task.checkCancellation()
                let count = min(65_536, LinkMIDIFile.maximumByteCount + 1 - data.count)
                guard let bytes = try handle.read(upToCount: count), !bytes.isEmpty else { break }
                data.append(bytes)
            }
            try Task.checkCancellation()
            guard data.count <= LinkMIDIFile.maximumByteCount else { throw MIDIFileTransferError.invalidSize }
            let after = try MIDIFileSnapshot.information(descriptor: descriptor)
            guard before == after, data.count == before.byteCount else { throw MIDIBatchError.sourceChanged }
            guard data.starts(with: Array("MThd".utf8)) else { throw MIDIBatchError.invalidHeader }
            let title = (item.relativePath as NSString).deletingPathExtension
            return LinkMIDIFile(title: title, data: data, activateOnImport: !selection.folder, importID: item.id)
        }
    }
}

/// The lease is shared with detached tasks and released only after the last
/// owner finishes; cancellation never stops access beneath ongoing file I/O.
private final class MIDISecurityScopeLease: @unchecked Sendable {
    let url: URL
    private let started: Bool
    init(url: URL) { self.url = url; started = url.startAccessingSecurityScopedResource() }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}

private struct MIDISelection: Sendable {
    let id = UUID()
    let url: URL
    let folder: Bool
    let lease: MIDISecurityScopeLease
    init(url: URL, folder: Bool) {
        lease = MIDISecurityScopeLease(url: url)
        self.url = url.standardizedFileURL
        self.folder = folder
    }
}

fileprivate struct MIDIFileSnapshot: Sendable, Equatable {
    let byteCount: Int
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let inode: UInt64
    let device: Int32
    let mode: mode_t
    var isSymlink: Bool { mode & S_IFMT == S_IFLNK }
    var isDirectory: Bool { mode & S_IFMT == S_IFDIR }
    var isRegular: Bool { mode & S_IFMT == S_IFREG }

    private init(_ info: stat) throws {
        guard info.st_size >= 0, info.st_size <= Int.max else { throw MIDIBatchError.sourceChanged }
        byteCount = Int(info.st_size)
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        inode = info.st_ino
        device = info.st_dev
        mode = info.st_mode
    }

    static func information(at url: URL) throws -> Self {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { Darwin.lstat($0!, &info) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try Self(info)
    }

    static func information(descriptor: Int32) throws -> Self {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try Self(info)
    }
}

private enum MIDIBatchError: LocalizedError {
    case notMIDIFile, notDirectory, unreadableDirectory, invalidHeader, symbolicLink, sourceChanged
    var errorDescription: String? {
        switch self {
        case .notMIDIFile: "请选择普通的 .mid 或 .midi 文件。"
        case .notDirectory: "请选择文件夹。"
        case .unreadableDirectory: "无法读取所选文件夹。"
        case .invalidHeader: "文件没有有效的 MIDI 文件头。"
        case .symbolicLink: "已跳过符号链接或离开所选文件夹的路径，请重新选择。"
        case .sourceChanged: "源文件自选择后已改变。请重新选择文件或文件夹，再发送新内容。"
        }
    }
}
