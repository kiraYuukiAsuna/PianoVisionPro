import Foundation

/// Keyboard-local coordinates: x rightward from the left edge, y up, z toward the player.
/// The front edge is z = 0, the rear edge is negative z, and white-key tops are y = 0.
public struct KeyGeometry: Identifiable, Codable, Sendable, Hashable {
    public var id: Int { note }
    public let note: Int
    public let isBlack: Bool
    public let centerX: Float
    public let width: Float
    public let depth: Float
    public let height: Float

    /// Black keys begin at the rear of the white keys, rather than at their front edge.
    public let centerZ: Float
    public var topY: Float { height }

    public init(note: Int, isBlack: Bool, centerX: Float, width: Float, depth: Float, height: Float, centerZ: Float? = nil) {
        self.note = note
        self.isBlack = isBlack
        self.centerX = centerX
        self.width = width
        self.depth = depth
        self.height = height
        self.centerZ = centerZ ?? -depth / 2
    }
}

public struct KeyboardLayout: Codable, Sendable, Hashable {
    public let minMIDINote: Int
    public let keyCount: Int
    public let whiteKeyWidth: Float
    public let whiteKeyDepth: Float
    public let blackKeyWidth: Float
    public let blackKeyDepth: Float
    public let blackKeyHeight: Float
    public let keys: [KeyGeometry]
    public let width: Float

    public init(
        minMIDINote: Int = 21,
        keyCount: Int = 88,
        whiteKeyWidth: Float = 0.0235,
        whiteKeyDepth: Float = 0.145,
        blackKeyWidth: Float = 0.0137,
        blackKeyDepth: Float = 0.09,
        blackKeyHeight: Float = 0.012
    ) {
        let first = min(127, max(0, minMIDINote))
        let count = min(128 - first, max(0, keyCount))
        let whiteWidth = whiteKeyWidth.isFinite && whiteKeyWidth > 0 ? whiteKeyWidth : 0.0235
        let whiteDepth = whiteKeyDepth.isFinite && whiteKeyDepth > 0 ? whiteKeyDepth : 0.145
        let blackWidth = blackKeyWidth.isFinite && blackKeyWidth > 0 ? blackKeyWidth : 0.0137
        let blackDepth = min(whiteDepth, blackKeyDepth.isFinite && blackKeyDepth > 0 ? blackKeyDepth : 0.09)
        let blackHeight = blackKeyHeight.isFinite ? max(0, blackKeyHeight) : 0.012
        self.minMIDINote = first
        self.keyCount = count
        self.whiteKeyWidth = whiteWidth
        self.whiteKeyDepth = whiteDepth
        self.blackKeyWidth = blackWidth
        self.blackKeyDepth = blackDepth
        self.blackKeyHeight = blackHeight

        // Count in diatonic coordinates so semitones are never treated as equally spaced.
        func whiteKeysBefore(_ note: Int) -> Int {
            let octave = note / 12
            let naturals = [0, 2, 4, 5, 7, 9, 11]
            return octave * 7 + naturals.filter { $0 < note % 12 }.count
        }
        func edges(_ note: Int) -> (Float, Float) {
            let preceding = Float(whiteKeysBefore(note)) * whiteWidth
            if Self.isBlack(note) { return (preceding - blackWidth / 2, preceding + blackWidth / 2) }
            return (preceding, preceding + whiteWidth)
        }
        let left = count > 0 ? edges(first).0 : 0
        let right = count > 0 ? edges(first + count - 1).1 : 0
        width = right - left
        keys = (first..<(first + count)).map { note in
            let black = Self.isBlack(note)
            let bounds = edges(note)
            return KeyGeometry(
                note: note,
                isBlack: black,
                centerX: (bounds.0 + bounds.1) / 2 - left,
                width: black ? blackWidth : whiteWidth,
                depth: black ? blackDepth : whiteDepth,
                height: black ? blackHeight : 0,
                centerZ: black ? -whiteDepth + blackDepth / 2 : -whiteDepth / 2
            )
        }
    }

    public func key(for pitch: Int) -> KeyGeometry? {
        let index = pitch - minMIDINote
        return keys.indices.contains(index) ? keys[index] : nil
    }

    public static func isBlack(_ pitch: Int) -> Bool {
        [1, 3, 6, 8, 10].contains((pitch % 12 + 12) % 12)
    }
}
