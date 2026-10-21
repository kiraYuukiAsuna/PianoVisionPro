import Foundation

public enum FingerKeyboardCalibrationError: Error, Equatable, Sendable, LocalizedError {
    case nonFinitePoint
    case invalidConfiguration
    case invalidKeyWidth
    case excessiveRoll

    public var errorDescription: String? {
        switch self {
        case .nonFinitePoint: "手指位置无效，请等待手部追踪恢复后重新采样。"
        case .invalidConfiguration: "琴键校准参数无效。"
        case .invalidKeyWidth: "两端距离与琴键宽度不符，请重新采集左右端白键前缘中心。"
        case .excessiveRoll: "两端高度差过大，请让指尖贴近同一琴面后重新采样。"
        }
    }
}

/// The two samples are the centres of the first and last white keys' front
/// edges, not the outside corners. An 88-key keyboard has 52 white keys, hence
/// 51 centre-to-centre intervals. +X follows ascending pitches and +Y is up.
public struct FingerKeyboardCalibration: Equatable, Sendable {
    public let translation: SIMD3<Float>
    public let yawDegrees: Float
    public let rollDegrees: Float
    /// Two points cannot resolve the keyboard's front-to-back inclination.
    public let pitchDegrees: Float
    public let whiteKeyWidth: Float

    public static func solve(
        leftFrontCenter left: SIMD3<Float>,
        rightFrontCenter right: SIMD3<Float>,
        whiteKeyIntervals: Int = 51,
        allowedWhiteKeyWidth: ClosedRange<Float> = 0.018...0.028,
        maximumRollDegrees: Float = 5
    ) throws -> Self {
        guard finite(left), finite(right) else { throw FingerKeyboardCalibrationError.nonFinitePoint }
        guard whiteKeyIntervals > 0,
              allowedWhiteKeyWidth.lowerBound.isFinite, allowedWhiteKeyWidth.upperBound.isFinite,
              allowedWhiteKeyWidth.lowerBound > 0,
              maximumRollDegrees.isFinite, maximumRollDegrees >= 0, maximumRollDegrees < 90 else {
            throw FingerKeyboardCalibrationError.invalidConfiguration
        }
        // Double intermediates avoid overflow when rejecting extreme finite input.
        let dx = Double(right.x) - Double(left.x)
        let dy = Double(right.y) - Double(left.y)
        let dz = Double(right.z) - Double(left.z)
        let horizontalSpan = sqrt(dx * dx + dz * dz)
        let span = sqrt(horizontalSpan * horizontalSpan + dy * dy)
        let width = Float(span / Double(whiteKeyIntervals))
        // Endpoints arrive as Float world coordinates, so even exact physical
        // boundary values can round just outside their allowed interval.
        let widthEpsilon = max(allowedWhiteKeyWidth.lowerBound.ulp, allowedWhiteKeyWidth.upperBound.ulp) * 4
        guard width.isFinite, width >= allowedWhiteKeyWidth.lowerBound - widthEpsilon,
              width <= allowedWhiteKeyWidth.upperBound + widthEpsilon else {
            throw FingerKeyboardCalibrationError.invalidKeyWidth
        }
        let roll = Float(atan2(dy, horizontalSpan) * 180 / .pi)
        guard horizontalSpan > 0, abs(roll) <= maximumRollDegrees + 0.0001 else {
            throw FingerKeyboardCalibrationError.excessiveRoll
        }
        return Self(
            translation: SIMD3(Float(Double(left.x) + dx / 2),
                               Float(Double(left.y) + dy / 2),
                               Float(Double(left.z) + dz / 2)),
            yawDegrees: Float(atan2(-dz, dx) * 180 / .pi),
            rollDegrees: min(maximumRollDegrees, max(-maximumRollDegrees, roll)),
            pitchDegrees: 0,
            whiteKeyWidth: min(allowedWhiteKeyWidth.upperBound, max(allowedWhiteKeyWidth.lowerBound, width))
        )
    }

    fileprivate static func finite(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }
}

/// A sliding, bounded window of tracked fingertip positions. The caller must
/// supply fresh provider timestamps and reset on tracking loss or a new target.
/// Joint coordinates are used unchanged; there is no assumed finger-pad offset.
public struct StableFingerPointSampler: Sendable {
    private struct Sample: Sendable {
        let timestamp: Double
        let position: SIMD3<Float>
    }

    public let duration: Double
    public let minimumSamples: Int
    public let maximumDeviation: Float
    public let maximumSamples: Int
    public var sampleCount: Int { samples.count }
    private var samples: [Sample] = []

    public init(duration: Double = 0.4, minimumSamples: Int = 8,
                maximumDeviation: Float = 0.006, maximumSamples: Int = 256) {
        self.duration = duration.isFinite && duration > 0 ? duration : 0.4
        self.minimumSamples = min(4096, max(2, minimumSamples))
        self.maximumDeviation = maximumDeviation.isFinite && maximumDeviation >= 0 ? maximumDeviation : 0.006
        self.maximumSamples = min(4096, max(self.minimumSamples, maximumSamples))
    }

    public mutating func reset() {
        samples.removeAll(keepingCapacity: true)
    }

    /// Returns a component-wise median only after a full stable window. Duplicate
    /// timestamps never count as new evidence. A backwards timestamp begins a new
    /// window; a gap longer than the entire window cannot bridge a tracking outage.
    public mutating func add(timestamp: Double, position: SIMD3<Float>) -> SIMD3<Float>? {
        guard timestamp.isFinite, FingerKeyboardCalibration.finite(position) else {
            reset()
            return nil
        }
        if let last = samples.last {
            if timestamp == last.timestamp { return nil }
            if timestamp < last.timestamp || timestamp - last.timestamp > duration { reset() }
        }
        samples.append(Sample(timestamp: timestamp, position: position))
        let cutoff = timestamp - duration
        // Retain the single sample straddling the lower boundary: dropping every
        // sample before the cutoff would make a nonintegral frame interval unable
        // to ever cover the requested duration.
        var obsolete = 0
        while obsolete + 1 < samples.count, samples[obsolete + 1].timestamp <= cutoff { obsolete += 1 }
        if obsolete > 0 { samples.removeFirst(obsolete) }
        if samples.count > maximumSamples { samples.removeFirst(samples.count - maximumSamples) }
        let epsilon = max(0.000000001, timestamp.ulp * 2)
        guard samples.count >= minimumSamples,
              let first = samples.first, timestamp - first.timestamp >= duration - epsilon else { return nil }

        func median(_ axis: Int) -> Float {
            let coordinates = samples.map { $0.position[axis] }.sorted()
            let middle = coordinates.count / 2
            if coordinates.count.isMultiple(of: 2) {
                return Float((Double(coordinates[middle - 1]) + Double(coordinates[middle])) / 2)
            }
            return coordinates[middle]
        }
        let point = SIMD3(median(0), median(1), median(2))
        let radiusSquared = Double(maximumDeviation) * Double(maximumDeviation)
        guard samples.allSatisfy({ sample in
            let dx = Double(sample.position.x) - Double(point.x)
            let dy = Double(sample.position.y) - Double(point.y)
            let dz = Double(sample.position.z) - Double(point.z)
            return dx * dx + dy * dy + dz * dz <= radiusSquared
        }) else { return nil }
        return point
    }
}
