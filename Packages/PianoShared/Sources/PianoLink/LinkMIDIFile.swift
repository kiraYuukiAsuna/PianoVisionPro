import Foundation

/// MIDI bytes stay on the local connection. The receiver chooses its own storage filename.
public struct LinkMIDIFile: Sendable, Equatable {
    public static let maximumByteCount = 20_000_000
    static let chunkByteCount = 16_384
    public let id: UUID
    public let title: String
    public let data: Data
    public let activateOnImport: Bool
    /// Stable queue-item identity across retry attempts; distinct from `id`.
    public let importID: UUID?

    public init(id: UUID = UUID(), title: String, data: Data, activateOnImport: Bool = true, importID: UUID? = nil) {
        self.id = id
        self.title = Self.safeTitle(title)
        self.data = data
        self.activateOnImport = activateOnImport
        self.importID = importID
    }

    static func safeTitle(_ value: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let sanitized = String(value.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined().prefix(128))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty || sanitized == "." || sanitized == ".." ? "导入曲目" : sanitized
    }
}

public enum MIDIFileTransferError: LocalizedError, Sendable, Equatable {
    case invalidSize, disconnected, busy, timedOut, invalidTransfer, rejected(String)
    public var errorDescription: String? {
        switch self {
        case .invalidSize: "MIDI 文件必须大于 0 字节且不超过 20 MB。"
        case .disconnected: "Vision Pro 已断开，曲目未收到导入确认。"
        case .busy: "已有曲目正在传输，请等待完成。"
        case .timedOut: "曲目传输或接收确认超时，请重新发送。"
        case .invalidTransfer: "曲目传输数据不完整或顺序错误，请重新发送。"
        case .rejected(let message): "Vision Pro 未能导入：\(message)"
        }
    }
}

struct LinkFilePayload: Codable, Sendable {
    let id: UUID
    var title: String? = nil
    var totalBytes: Int? = nil
    /// -1 acknowledges begin; nonnegative values identify consecutive data chunks.
    var index: Int? = nil
    var data: Data? = nil
    var accepted: Bool? = nil
    var message: String? = nil
    var activateOnImport: Bool? = nil
    var importID: UUID? = nil
}

/// Strict, bounded assembly independent of UI and networking callbacks.
struct MIDIFileAssembly {
    let id: UUID
    let title: String
    let totalBytes: Int
    let activateOnImport: Bool
    let importID: UUID?
    private(set) var nextIndex = 0
    private(set) var data = Data()

    init(_ begin: LinkFilePayload) throws {
        guard let size = begin.totalBytes, size > 0, size <= LinkMIDIFile.maximumByteCount else {
            throw MIDIFileTransferError.invalidSize
        }
        guard let title = begin.title, begin.data == nil else { throw MIDIFileTransferError.invalidTransfer }
        id = begin.id
        self.title = LinkMIDIFile.safeTitle(title)
        totalBytes = size
        activateOnImport = begin.activateOnImport ?? true
        importID = begin.importID
        data.reserveCapacity(size)
    }

    mutating func append(_ chunk: LinkFilePayload) throws {
        guard chunk.id == id, chunk.index == nextIndex, let bytes = chunk.data,
              !bytes.isEmpty, bytes.count <= LinkMIDIFile.chunkByteCount,
              bytes.count <= totalBytes - data.count else { throw MIDIFileTransferError.invalidTransfer }
        data.append(bytes)
        nextIndex += 1
    }

    func finish(_ end: LinkFilePayload) throws -> LinkMIDIFile {
        guard end.id == id, end.index == nextIndex, end.data == nil, data.count == totalBytes else {
            throw MIDIFileTransferError.invalidTransfer
        }
        return LinkMIDIFile(id: id, title: title, data: data, activateOnImport: activateOnImport, importID: importID)
    }
}
