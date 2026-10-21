import XCTest
@testable import PianoCore

final class FingerKeyboardCalibrationTests: XCTestCase {
    private func endpoints(width: Float = 0.0235, yaw: Float = 0, roll: Float = 0,
                           center: SIMD3<Float> = [0, 0.72, -0.6]) -> (SIMD3<Float>, SIMD3<Float>) {
        let y = Double(yaw) * .pi / 180
        let r = Double(roll) * .pi / 180
        let axis = SIMD3<Float>(Float(cos(y) * cos(r)), Float(sin(r)), Float(-sin(y) * cos(r)))
        let halfSpan = axis * (width * 51 / 2)
        return (center - halfSpan, center + halfSpan)
    }

    func testDefault88KeysUse51WhiteKeyCentreIntervalsAndMidpointOrigin() throws {
        let (left, right) = endpoints()
        let result = try FingerKeyboardCalibration.solve(leftFrontCenter: left, rightFrontCenter: right)
        XCTAssertEqual(result.whiteKeyWidth, 0.0235, accuracy: 0.000001)
        XCTAssertEqual(result.translation, SIMD3<Float>(0, 0.72, -0.6))
        XCTAssertEqual(result.yawDegrees, 0, accuracy: 0.00001)
        XCTAssertEqual(result.rollDegrees, 0, accuracy: 0.00001)
        XCTAssertEqual(result.pitchDegrees, 0)
    }

    func testArbitraryKeyboardDirectionsDoNotAssumeWorldLeftAndRight() throws {
        for yaw: Float in [-180, -135, -90, 0, 90, 150, 180] {
            let center = SIMD3<Float>(2.3, 0.85, -1.1)
            let (left, right) = endpoints(width: 0.024, yaw: yaw, roll: 3, center: center)
            let result = try FingerKeyboardCalibration.solve(leftFrontCenter: left, rightFrontCenter: right)
            XCTAssertEqual(result.translation.x, center.x, accuracy: 0.000001)
            XCTAssertEqual(result.translation.y, center.y, accuracy: 0.000001)
            XCTAssertEqual(result.translation.z, center.z, accuracy: 0.000001)
            XCTAssertEqual(result.whiteKeyWidth, 0.024, accuracy: 0.000001)
            XCTAssertEqual(result.rollDegrees, 3, accuracy: 0.0001)
            XCTAssertEqual(cos(Double(result.yawDegrees) * .pi / 180), cos(Double(yaw) * .pi / 180), accuracy: 0.000001)
            XCTAssertEqual(sin(Double(result.yawDegrees) * .pi / 180), sin(Double(yaw) * .pi / 180), accuracy: 0.000001)
        }
    }

    func testTiltedSpanUsesPhysicalLengthRatherThanHorizontalProjection() throws {
        let (left, right) = endpoints(width: 0.0235, yaw: 42, roll: -4.8)
        let result = try FingerKeyboardCalibration.solve(leftFrontCenter: left, rightFrontCenter: right)
        XCTAssertEqual(result.whiteKeyWidth, 0.0235, accuracy: 0.000001)
        XCTAssertEqual(result.rollDegrees, -4.8, accuracy: 0.0001)
        XCTAssertEqual(result.yawDegrees, 42, accuracy: 0.0001)
    }

    func testAllowedWidthAndRollBoundaries() throws {
        for width: Float in [0.018, 0.028] {
            let (left, right) = endpoints(width: width)
            XCTAssertEqual(try FingerKeyboardCalibration.solve(leftFrontCenter: left, rightFrontCenter: right).whiteKeyWidth,
                           width, accuracy: 0.000001)
        }
        for roll: Float in [-5, 5] {
            let (left, right) = endpoints(roll: roll)
            XCTAssertEqual(try FingerKeyboardCalibration.solve(leftFrontCenter: left, rightFrontCenter: right).rollDegrees,
                           roll, accuracy: 0.00001)
        }
    }

    func testRejectsInvalidSpacingAndExcessiveHeightDifference() {
        for width: Float in [0, 0.017, 0.029] {
            let (left, right) = endpoints(width: width)
            XCTAssertThrowsError(try FingerKeyboardCalibration.solve(leftFrontCenter: left, rightFrontCenter: right)) {
                XCTAssertEqual($0 as? FingerKeyboardCalibrationError, .invalidKeyWidth)
            }
        }
        for roll: Float in [-6, 6, 90] {
            let (left, right) = endpoints(roll: roll)
            XCTAssertThrowsError(try FingerKeyboardCalibration.solve(leftFrontCenter: left, rightFrontCenter: right)) {
                XCTAssertEqual($0 as? FingerKeyboardCalibrationError, .excessiveRoll)
            }
        }
    }

    func testRejectsNonFiniteAndExtremePointsWithoutOverflowing() {
        for value: Float in [.nan, .infinity, -.infinity] {
            for axis in 0..<3 {
                var left = SIMD3<Float>(0, 0, 0)
                left[axis] = value
                XCTAssertThrowsError(try FingerKeyboardCalibration.solve(leftFrontCenter: left, rightFrontCenter: [1.2, 0, 0])) {
                    XCTAssertEqual($0 as? FingerKeyboardCalibrationError, .nonFinitePoint)
                }
                XCTAssertThrowsError(try FingerKeyboardCalibration.solve(leftFrontCenter: [0, 0, 0], rightFrontCenter: left))
            }
        }
        XCTAssertThrowsError(try FingerKeyboardCalibration.solve(leftFrontCenter: [.greatestFiniteMagnitude, 0, 0],
                                                                  rightFrontCenter: [-.greatestFiniteMagnitude, 0, 0]))
    }

    func testCustomKeyCountAndBadConfiguration() throws {
        let result = try FingerKeyboardCalibration.solve(leftFrontCenter: [0, 1, 0], rightFrontCenter: [0.1645, 1, 0],
                                                        whiteKeyIntervals: 7)
        XCTAssertEqual(result.whiteKeyWidth, 0.0235, accuracy: 0.000001)
        XCTAssertThrowsError(try FingerKeyboardCalibration.solve(leftFrontCenter: [0, 0, 0], rightFrontCenter: [1.2, 0, 0],
                                                                  whiteKeyIntervals: 0)) {
            XCTAssertEqual($0 as? FingerKeyboardCalibrationError, .invalidConfiguration)
        }
        XCTAssertThrowsError(try FingerKeyboardCalibration.solve(leftFrontCenter: [0, 0, 0], rightFrontCenter: [1.2, 0, 0],
                                                                  maximumRollDegrees: .nan))
    }

    func testStableSamplerNeedsEightDistinctSamplesAndFullDuration() {
        var sampler = StableFingerPointSampler()
        let position = SIMD3<Float>(0.25, 0.75, -0.5)
        for index in 0..<7 {
            XCTAssertNil(sampler.add(timestamp: Double(index) * 0.4 / 7, position: position))
        }
        XCTAssertEqual(sampler.add(timestamp: 0.4, position: position), position)
        XCTAssertEqual(sampler.sampleCount, 8)

        sampler.reset()
        for index in 0..<8 {
            XCTAssertNil(sampler.add(timestamp: Double(index) * 0.03, position: position))
        }
        XCTAssertEqual(sampler.add(timestamp: 0.4, position: position), position)
    }

    func testDuplicateTimestampsNeverFillTheSamplingWindow() {
        var sampler = StableFingerPointSampler()
        for _ in 0..<100 { XCTAssertNil(sampler.add(timestamp: 0, position: .zero)) }
        XCTAssertEqual(sampler.sampleCount, 1)
        for index in 1...4 { XCTAssertNil(sampler.add(timestamp: Double(index) * 0.1, position: .zero)) }
        XCTAssertEqual(sampler.sampleCount, 5)
    }

    func testMedianAndThreeDimensionalDeviationAreUsed() {
        var sampler = StableFingerPointSampler()
        let center = SIMD3<Float>(0.1, 0.8, -0.7)
        var stable: SIMD3<Float>?
        for index in 0...8 {
            let delta: Float = index.isMultiple(of: 2) ? 0.002 : -0.002
            stable = sampler.add(timestamp: Double(index) * 0.05, position: center + SIMD3(delta, delta, 0))
        }
        XCTAssertEqual(stable, center + SIMD3<Float>(0.002, 0.002, 0))

        sampler.reset()
        for index in 0...8 {
            let point: SIMD3<Float> = index == 4 ? [0.005, 0.005, 0] : .zero
            XCTAssertNil(sampler.add(timestamp: Double(index) * 0.05, position: point),
                         "Each coordinate is below 6mm, but total 3D movement is not")
        }
    }

    func testAnOutlierBlocksCaptureThenAgesOutOfTheSlidingWindow() {
        var sampler = StableFingerPointSampler()
        for index in 0...8 {
            XCTAssertNil(sampler.add(timestamp: Double(index) * 0.05,
                                     position: index == 1 ? [0.02, 0, 0] : .zero))
        }
        var stable: SIMD3<Float>?
        for index in 9...11 { stable = sampler.add(timestamp: Double(index) * 0.05, position: .zero) }
        XCTAssertEqual(stable, .zero)
    }

    func testNonIntegralFrameIntervalsCanCoverAContinuousWindow() {
        var sampler = StableFingerPointSampler()
        var stable: SIMD3<Float>?
        for index in 0...30 { stable = sampler.add(timestamp: 100 + Double(index) / 59, position: [1, 2, 3]) }
        XCTAssertEqual(stable, SIMD3<Float>(1, 2, 3))
        XCTAssertLessThan(sampler.sampleCount, 30)
    }

    func testTrackingLossResetBackwardsTimeAndInvalidDataClearEvidence() {
        var sampler = StableFingerPointSampler()
        for index in 0...8 { _ = sampler.add(timestamp: Double(index) * 0.05, position: .zero) }
        sampler.reset()
        XCTAssertEqual(sampler.sampleCount, 0)
        XCTAssertNil(sampler.add(timestamp: 1, position: .zero))
        XCTAssertNil(sampler.add(timestamp: 0.5, position: .zero))
        XCTAssertEqual(sampler.sampleCount, 1)
        XCTAssertNil(sampler.add(timestamp: .nan, position: .zero))
        XCTAssertEqual(sampler.sampleCount, 0)
        _ = sampler.add(timestamp: 1, position: .zero)
        XCTAssertNil(sampler.add(timestamp: 1.1, position: [.infinity, 0, 0]))
        XCTAssertEqual(sampler.sampleCount, 0)
    }

    func testLongTimestampGapCannotBridgeAStoppedTrackingStream() {
        var sampler = StableFingerPointSampler()
        for index in 0..<7 { _ = sampler.add(timestamp: Double(index) * 0.05, position: .zero) }
        XCTAssertNil(sampler.add(timestamp: 10, position: .zero))
        XCTAssertEqual(sampler.sampleCount, 1)
    }

    func testSamplerStorageIsBoundedAndParametersAreInjectable() {
        var bounded = StableFingerPointSampler(duration: 100, minimumSamples: 8, maximumSamples: 32)
        for index in 0..<1000 { XCTAssertNil(bounded.add(timestamp: Double(index) / 100, position: .zero)) }
        XCTAssertEqual(bounded.sampleCount, 32)

        var short = StableFingerPointSampler(duration: 0.1, minimumSamples: 3, maximumDeviation: 0.001, maximumSamples: 4)
        XCTAssertNil(short.add(timestamp: 0, position: .zero))
        XCTAssertNil(short.add(timestamp: 0.05, position: [0.0005, 0, 0]))
        XCTAssertEqual(short.add(timestamp: 0.1, position: .zero), .zero)
        let sanitized = StableFingerPointSampler(duration: .nan, minimumSamples: -1, maximumDeviation: -.infinity, maximumSamples: -1)
        XCTAssertEqual(sanitized.duration, 0.4)
        XCTAssertEqual(sanitized.minimumSamples, 2)
        XCTAssertEqual(sanitized.maximumSamples, 2)
        XCTAssertEqual(sanitized.maximumDeviation, 0.006)
    }
}
