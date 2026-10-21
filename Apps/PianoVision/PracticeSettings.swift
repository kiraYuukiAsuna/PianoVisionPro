import Foundation
import PianoCore

enum PracticeMode: String, Codable, CaseIterable {
    case automatic, waitForNotes
}

struct PracticeSettings: Codable {
    static let currentPreferenceVersion = 2
    static let defaultTargetAlignmentMilliseconds = 2000.0
    private(set) var preferenceVersion = 2
    var mode: PracticeMode
    var automaticHandSplit: Bool
    var splitPitch: Int
    var showFingering: Bool
    var targetAlignmentMilliseconds = 2000.0
}

extension PracticeSettings {
    private enum CodingKeys: String, CodingKey {
        case preferenceVersion, mode, automaticHandSplit, splitPitch, showFingering, targetAlignmentMilliseconds
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decode(PracticeMode.self, forKey: .mode)
        automaticHandSplit = try values.decode(Bool.self, forKey: .automaticHandSplit)
        splitPitch = try values.decode(Int.self, forKey: .splitPitch)
        showFingering = try values.decode(Bool.self, forKey: .showFingering)
        let storedVersion = try values.decodeIfPresent(Int.self, forKey: .preferenceVersion) ?? 0
        targetAlignmentMilliseconds = try values.decodeIfPresent(Double.self, forKey: .targetAlignmentMilliseconds)
            ?? Self.defaultTargetAlignmentMilliseconds
        // A version marker lets a user explicitly return to 800ms after the
        // upgrade without having that later choice reset on every launch.
        if storedVersion < Self.currentPreferenceVersion, targetAlignmentMilliseconds == 800 {
            targetAlignmentMilliseconds = Self.defaultTargetAlignmentMilliseconds
        }
        preferenceVersion = max(storedVersion, Self.currentPreferenceVersion)
    }
}

struct SongPracticeAnnotations: Codable {
    var trackHands: [Int: PianoHand]
    var fingerOverrides: [Int: Int]
}
