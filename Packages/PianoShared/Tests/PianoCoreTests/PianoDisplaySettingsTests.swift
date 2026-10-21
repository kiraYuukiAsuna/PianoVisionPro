import Foundation
import XCTest
@testable import PianoCore

final class PianoDisplaySettingsTests: XCTestCase {
    func testTrackDefaultMigratesOnceWithoutResettingCustomVersionTwoPreferences() throws {
        let data = Data(#"{"preferenceVersion":2,"contrastVersion":1,"rollLengthMeters":1.1,"lookAheadSeconds":7,"noteOpacity":0.92,"highlightOpacity":0.64,"feedbackOpacity":0.96,"templateOpacity":0.30}"#.utf8)
        var migrated = try JSONDecoder().decode(PianoDisplaySettings.self, from: data)
        XCTAssertEqual(migrated.rollLengthMeters, 1.5)
        XCTAssertEqual(migrated.lookAheadSeconds, 7)
        XCTAssertEqual(migrated.noteOpacity, 0.92)
        XCTAssertEqual(migrated.highlightOpacity, 0.64)
        XCTAssertEqual(migrated.feedbackOpacity, 0.96)
        XCTAssertEqual(migrated.templateOpacity, 0.30)
        migrated.rollLengthMeters = 1.1
        for _ in 0..<3 {
            migrated = try JSONDecoder().decode(PianoDisplaySettings.self, from: JSONEncoder().encode(migrated))
            XCTAssertEqual(migrated.rollLengthMeters, 1.1)
        }
        let custom = try JSONDecoder().decode(PianoDisplaySettings.self,
            from: Data(#"{"preferenceVersion":2,"rollLengthMeters":0.75,"lookAheadSeconds":8.5}"#.utf8))
        XCTAssertEqual(custom.rollLengthMeters, 0.75)
        XCTAssertEqual(custom.lookAheadSeconds, 8.5)
    }

    func testNewDefaultsUseOpaqueFeedbackWithoutAPracticeTemplate() {
        let value = PianoDisplaySettings()
        XCTAssertEqual(value.noteOpacity, 1)
        XCTAssertEqual(value.highlightOpacity, 1)
        XCTAssertEqual(value.feedbackOpacity, 1)
        XCTAssertEqual(value.templateOpacity, 0)
        XCTAssertEqual(value.preferenceVersion, PianoDisplaySettings.currentPreferenceVersion)
    }

    func testPartialPreferencesUseDefaultsForNewControls() throws {
        let value = try JSONDecoder().decode(PianoDisplaySettings.self, from: Data(#"{"noteOpacity":0.2,"showsHoldReleaseGuides":true}"#.utf8))
        XCTAssertEqual(value.noteOpacity, 0.2)
        XCTAssertEqual(value.highlightOpacity, PianoDisplaySettings().highlightOpacity)
        XCTAssertEqual(value.noteGapMillimeters, 3)
        XCTAssertEqual(value.noteThicknessMillimeters, 8)
        XCTAssertTrue(value.showsOnsetMarkers)
        XCTAssertEqual(value.lookAheadSeconds, 5)
        XCTAssertEqual(value.rollLengthMeters, 1.5)
        XCTAssertTrue(value.fadesDistantNotes)
        XCTAssertTrue(value.showsLaneLandmarks)
        XCTAssertTrue(value.showsBeatGrid)
        XCTAssertTrue(value.showsKeyConnectors)
        XCTAssertEqual(try JSONDecoder().decode(PianoDisplaySettings.self, from: JSONEncoder().encode(value)), value)
    }

    func testStoredOutOfRangeSettingsCannotMakeGeometryInvalid() throws {
        let value = try JSONDecoder().decode(PianoDisplaySettings.self, from:
            Data(#"{"noteOpacity":-2,"highlightOpacity":3,"noteGapMillimeters":-1,"rearOffsetMeters":-1,"surfaceHeightMeters":12}"#.utf8))
        XCTAssertEqual(value.noteOpacity, 0)
        XCTAssertEqual(value.highlightOpacity, 1)
        XCTAssertEqual(value.noteGapMillimeters, 0)
        XCTAssertEqual(value.rearOffsetMeters, 0)
        XCTAssertEqual(value.surfaceHeightMeters, 0.2)
    }

    func testOriginalFaintDefaultsUpgradeToReadablePressedFeedback() throws {
        let value = try JSONDecoder().decode(PianoDisplaySettings.self, from:
            Data(#"{"noteOpacity":0.8,"highlightOpacity":0.32,"feedbackOpacity":0.62,"templateOpacity":0.18}"#.utf8))
        XCTAssertEqual(value.noteOpacity, PianoDisplaySettings().noteOpacity)
        XCTAssertEqual(value.feedbackOpacity, 1)
        XCTAssertEqual(value.highlightOpacity, 1)
        XCTAssertEqual(value.templateOpacity, 0)
        XCTAssertTrue(value.showsKeyboardGuides)
    }

    func testRecentDefaultsMigratePerFieldAndWriteTheNewVersion() throws {
        let decoded = try JSONDecoder().decode(PianoDisplaySettings.self, from:
            Data(#"{"contrastVersion":1,"noteOpacity":0.92,"highlightOpacity":0.64,"feedbackOpacity":0.96,"templateOpacity":0.30,"noteGapMillimeters":7,"showsKeyboardGuides":false}"#.utf8))
        XCTAssertEqual(decoded.noteOpacity, 1)
        XCTAssertEqual(decoded.highlightOpacity, 1)
        XCTAssertEqual(decoded.feedbackOpacity, 1)
        XCTAssertEqual(decoded.templateOpacity, 0)
        XCTAssertEqual(decoded.noteGapMillimeters, 7)
        XCTAssertFalse(decoded.showsKeyboardGuides)
        let encoded = try JSONEncoder().encode(decoded)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["preferenceVersion"] as? Int, PianoDisplaySettings.currentPreferenceVersion)
        XCTAssertEqual(try JSONDecoder().decode(PianoDisplaySettings.self, from: encoded), decoded)
    }

    func testMixedLegacyCustomValuesSurviveDefaultMigration() throws {
        let decoded = try JSONDecoder().decode(PianoDisplaySettings.self, from:
            Data(#"{"contrastVersion":1,"noteOpacity":0.23,"highlightOpacity":0.64,"feedbackOpacity":0.73,"templateOpacity":0.17}"#.utf8))
        XCTAssertEqual(decoded.noteOpacity, 0.23)
        XCTAssertEqual(decoded.highlightOpacity, 1)
        XCTAssertEqual(decoded.feedbackOpacity, 0.73)
        XCTAssertEqual(decoded.templateOpacity, 0.17)
        let olderValuesChosenLater = try JSONDecoder().decode(PianoDisplaySettings.self, from:
            Data(#"{"contrastVersion":1,"noteOpacity":0.8,"highlightOpacity":0.32,"feedbackOpacity":0.62,"templateOpacity":0.18}"#.utf8))
        XCTAssertEqual(olderValuesChosenLater.noteOpacity, 0.8)
        XCTAssertEqual(olderValuesChosenLater.highlightOpacity, 0.32)
        XCTAssertEqual(olderValuesChosenLater.feedbackOpacity, 0.62)
        XCTAssertEqual(olderValuesChosenLater.templateOpacity, 0.18)
    }

    func testCurrentVersionCanExplicitlyChooseFormerDefaultsWithoutMigratingAgain() throws {
        var settings = PianoDisplaySettings()
        settings.noteOpacity = 0.92
        settings.highlightOpacity = 0.64
        settings.feedbackOpacity = 0.96
        settings.templateOpacity = 0.30
        for _ in 0..<3 {
            settings = try JSONDecoder().decode(PianoDisplaySettings.self, from: JSONEncoder().encode(settings))
            XCTAssertEqual(settings.noteOpacity, 0.92)
            XCTAssertEqual(settings.highlightOpacity, 0.64)
            XCTAssertEqual(settings.feedbackOpacity, 0.96)
            XCTAssertEqual(settings.templateOpacity, 0.30)
        }
    }

    func testNewerPreferenceVersionsAreNotTreatedAsLegacyDefaults() throws {
        let settings = try JSONDecoder().decode(PianoDisplaySettings.self, from:
            Data(#"{"preferenceVersion":99,"noteOpacity":0.92,"highlightOpacity":0.64,"feedbackOpacity":0.96,"templateOpacity":0.30}"#.utf8))
        XCTAssertEqual(settings.preferenceVersion, 99)
        XCTAssertEqual(settings.noteOpacity, 0.92)
        XCTAssertEqual(settings.highlightOpacity, 0.64)
        XCTAssertEqual(settings.feedbackOpacity, 0.96)
        XCTAssertEqual(settings.templateOpacity, 0.30)
    }

    func testCustomTransparencyAndHiddenGuidesSurviveRoundTrip() throws {
        let legacy = try JSONDecoder().decode(PianoDisplaySettings.self, from:
            Data(#"{"noteOpacity":0.4,"highlightOpacity":0,"feedbackOpacity":0.2,"templateOpacity":0.7}"#.utf8))
        XCTAssertEqual(legacy.feedbackOpacity, 0.2)
        XCTAssertEqual(legacy.highlightOpacity, 0)
        XCTAssertEqual(legacy.templateOpacity, 0.7)
        var current = PianoDisplaySettings()
        current.feedbackOpacity = 0.62
        current.showsKeyboardGuides = false
        let restored = try JSONDecoder().decode(PianoDisplaySettings.self, from: JSONEncoder().encode(current))
        XCTAssertEqual(restored.feedbackOpacity, 0.62, "Newly chosen transparency must not undergo legacy migration")
        XCTAssertFalse(restored.showsKeyboardGuides)
    }

    func testNoteThicknessPersistsAndClampsWithoutChangingPlacement() throws {
        var settings = PianoDisplaySettings()
        settings.noteThicknessMillimeters = 12
        settings.surfaceHeightMeters = 0.04
        settings.rearOffsetMeters = 0.06
        let restored = try JSONDecoder().decode(PianoDisplaySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.noteThicknessMillimeters, 12)
        XCTAssertEqual(restored.surfaceHeightMeters, 0.04)
        XCTAssertEqual(restored.rearOffsetMeters, 0.06)
        settings.noteThicknessMillimeters = 100
        XCTAssertEqual(settings.validated().noteThicknessMillimeters, 20)
        settings.noteThicknessMillimeters = 0
        XCTAssertEqual(settings.validated().noteThicknessMillimeters, 2)
        settings.noteThicknessMillimeters = .nan
        XCTAssertEqual(settings.validated().noteThicknessMillimeters, 8)
    }

    func testPreviewAndGuideChoicesSurviveRoundTrip() throws {
        var settings = PianoDisplaySettings()
        settings.lookAheadSeconds = 8.5
        settings.rollLengthMeters = 0.75
        settings.fadesDistantNotes = false
        settings.farFadeStrength = 0.3
        settings.showsLaneLandmarks = false
        settings.showsBeatGrid = false
        settings.showsKeyConnectors = false
        let restored = try JSONDecoder().decode(PianoDisplaySettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
    }

    func testPreviewBoundsAndNonFiniteValuesAreSafe() throws {
        let decoded = try JSONDecoder().decode(PianoDisplaySettings.self, from:
            Data(#"{"lookAheadSeconds":100,"rollLengthMeters":-1,"farFadeStrength":3}"#.utf8))
        XCTAssertEqual(decoded.lookAheadSeconds, 10)
        XCTAssertEqual(decoded.rollLengthMeters, 0.35)
        XCTAssertEqual(decoded.farFadeStrength, 1)
        var settings = PianoDisplaySettings()
        settings.lookAheadSeconds = .nan
        settings.rollLengthMeters = .infinity
        settings.farFadeStrength = -.infinity
        XCTAssertEqual(settings.validated().lookAheadSeconds, 5)
        XCTAssertEqual(settings.validated().rollLengthMeters, 1.5)
        XCTAssertEqual(settings.validated().farFadeStrength, 0.65)
        settings.lookAheadSeconds = 0
        settings.rollLengthMeters = 10
        settings.farFadeStrength = -1
        XCTAssertEqual(settings.validated().lookAheadSeconds, 2)
        XCTAssertEqual(settings.validated().rollLengthMeters, 2)
        XCTAssertEqual(settings.validated().farFadeStrength, 0)
    }

    func testLegacyDisplayPreferencesDoNotReinterpretScrollSpeedAsTrackLength() throws {
        let restored = try JSONDecoder().decode(PianoDisplaySettings.self, from:
            Data(#"{"scrollSpeed":0.6,"noteGapMillimeters":7,"showsOnsetMarkers":false}"#.utf8))
        XCTAssertEqual(restored.lookAheadSeconds, 5)
        XCTAssertEqual(restored.rollLengthMeters, 1.5)
        XCTAssertEqual(restored.noteGapMillimeters, 7)
        XCTAssertFalse(restored.showsOnsetMarkers)
    }
}
