import Foundation

public struct PianoDisplaySettings: Codable, Equatable, Sendable {
    public static let currentPreferenceVersion = 3
    public private(set) var preferenceVersion = 3
    public var noteOpacity = 1.0
    public var noteThicknessMillimeters = 8.0
    public var highlightOpacity = 1.0
    public var feedbackOpacity = 1.0
    public var templateOpacity = 0.0
    public var noteGapMillimeters = 3.0
    public var rearOffsetMeters = 0.02
    public var surfaceHeightMeters = 0.018
    public var showsOnsetMarkers = true
    public var showsKeyboardGuides = true
    /// Real time available to read upcoming notes, independent of playback rate.
    public var lookAheadSeconds = 5.0
    public var rollLengthMeters = 1.5
    public var fadesDistantNotes = true
    public var farFadeStrength = 0.65
    public var showsLaneLandmarks = true
    public var showsBeatGrid = true
    public var showsKeyConnectors = true
    private var contrastVersion = 1

    public init() {}

    public func validated() -> Self {
        var result = self
        let defaults = Self()
        func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
            value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
        }
        result.noteOpacity = clamp(noteOpacity, 0...1, fallback: defaults.noteOpacity)
        result.noteThicknessMillimeters = clamp(noteThicknessMillimeters, 2...20, fallback: 8)
        result.highlightOpacity = clamp(highlightOpacity, 0...1, fallback: defaults.highlightOpacity)
        result.feedbackOpacity = clamp(feedbackOpacity, 0...1, fallback: defaults.feedbackOpacity)
        result.templateOpacity = clamp(templateOpacity, 0...1, fallback: defaults.templateOpacity)
        result.noteGapMillimeters = clamp(noteGapMillimeters, 0...10, fallback: 3)
        result.rearOffsetMeters = clamp(rearOffsetMeters, 0...0.4, fallback: 0.02)
        result.surfaceHeightMeters = clamp(surfaceHeightMeters, 0...0.2, fallback: 0.018)
        result.lookAheadSeconds = clamp(lookAheadSeconds, 2...10, fallback: defaults.lookAheadSeconds)
        result.rollLengthMeters = clamp(rollLengthMeters, 0.35...2, fallback: defaults.rollLengthMeters)
        result.farFadeStrength = clamp(farFadeStrength, 0...1, fallback: defaults.farFadeStrength)
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case preferenceVersion
        case noteOpacity, noteThicknessMillimeters, highlightOpacity, feedbackOpacity, templateOpacity
        case noteGapMillimeters, rearOffsetMeters, surfaceHeightMeters, showsOnsetMarkers, showsKeyboardGuides, contrastVersion
        case lookAheadSeconds, rollLengthMeters, fadesDistantNotes, farFadeStrength
        case showsLaneLandmarks, showsBeatGrid, showsKeyConnectors
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        noteOpacity = try values.decodeIfPresent(Double.self, forKey: .noteOpacity) ?? noteOpacity
        noteThicknessMillimeters = try values.decodeIfPresent(Double.self, forKey: .noteThicknessMillimeters) ?? noteThicknessMillimeters
        highlightOpacity = try values.decodeIfPresent(Double.self, forKey: .highlightOpacity) ?? highlightOpacity
        feedbackOpacity = try values.decodeIfPresent(Double.self, forKey: .feedbackOpacity) ?? feedbackOpacity
        templateOpacity = try values.decodeIfPresent(Double.self, forKey: .templateOpacity) ?? templateOpacity
        noteGapMillimeters = try values.decodeIfPresent(Double.self, forKey: .noteGapMillimeters) ?? noteGapMillimeters
        rearOffsetMeters = try values.decodeIfPresent(Double.self, forKey: .rearOffsetMeters) ?? rearOffsetMeters
        surfaceHeightMeters = try values.decodeIfPresent(Double.self, forKey: .surfaceHeightMeters) ?? surfaceHeightMeters
        showsOnsetMarkers = try values.decodeIfPresent(Bool.self, forKey: .showsOnsetMarkers) ?? showsOnsetMarkers
        showsKeyboardGuides = try values.decodeIfPresent(Bool.self, forKey: .showsKeyboardGuides) ?? showsKeyboardGuides
        lookAheadSeconds = try values.decodeIfPresent(Double.self, forKey: .lookAheadSeconds) ?? lookAheadSeconds
        rollLengthMeters = try values.decodeIfPresent(Double.self, forKey: .rollLengthMeters) ?? rollLengthMeters
        fadesDistantNotes = try values.decodeIfPresent(Bool.self, forKey: .fadesDistantNotes) ?? fadesDistantNotes
        farFadeStrength = try values.decodeIfPresent(Double.self, forKey: .farFadeStrength) ?? farFadeStrength
        showsLaneLandmarks = try values.decodeIfPresent(Bool.self, forKey: .showsLaneLandmarks) ?? showsLaneLandmarks
        showsBeatGrid = try values.decodeIfPresent(Bool.self, forKey: .showsBeatGrid) ?? showsBeatGrid
        showsKeyConnectors = try values.decodeIfPresent(Bool.self, forKey: .showsKeyConnectors) ?? showsKeyConnectors
        let storedVersion = try values.decodeIfPresent(Int.self, forKey: .preferenceVersion) ?? 0
        let storedContrastVersion = try values.decodeIfPresent(Int.self, forKey: .contrastVersion)
        if storedVersion < 2 {
            // Only unversioned/older preferences need this one-time upgrade.
            // Exact former defaults migrate per field; other chosen values stay
            // intact. The contrast marker distinguishes original faint defaults
            // from those same values deliberately chosen by a later user.
            let hasOriginalDefaults = storedContrastVersion == nil
            if noteOpacity == 0.92 || (hasOriginalDefaults && noteOpacity == 0.80) { noteOpacity = Self().noteOpacity }
            if highlightOpacity == 0.64 || (hasOriginalDefaults && highlightOpacity == 0.32) { highlightOpacity = Self().highlightOpacity }
            if feedbackOpacity == 0.96 || (hasOriginalDefaults && feedbackOpacity == 0.62) { feedbackOpacity = Self().feedbackOpacity }
            if templateOpacity == 0.30 || (hasOriginalDefaults && templateOpacity == 0.18) { templateOpacity = Self().templateOpacity }
        }
        // Upgrade only the former track default, once. Later explicit choices
        // of 110 cm remain valid, and custom preview/opacity values are retained.
        if storedVersion < 3, rollLengthMeters == 1.1 { rollLengthMeters = Self().rollLengthMeters }
        preferenceVersion = max(storedVersion, Self.currentPreferenceVersion)
        contrastVersion = max(storedContrastVersion ?? 1, 1)
        self = validated()
    }
}
