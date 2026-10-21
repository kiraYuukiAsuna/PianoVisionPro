// Headless substitute for the AR-only dependency; PianoSession.swift itself is compiled unchanged.
@MainActor final class SpatialCalibration {
    var isTracked = true
    var isFingerCalibrationActive = false
    var hasFingerCalibrationFirstPoint = false
}
