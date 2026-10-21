import Foundation

public struct PianoTempoChange: Codable, Sendable, Hashable {
    public let quarterPosition: Double
    public let microsecondsPerQuarter: Int

    public init(quarterPosition: Double, microsecondsPerQuarter: Int) {
        self.quarterPosition = quarterPosition
        self.microsecondsPerQuarter = microsecondsPerQuarter
    }
}

public struct PianoTimeSignature: Codable, Sendable, Hashable {
    public let quarterPosition: Double
    public let numerator: Int
    public let denominator: Int
    public let clocksPerMetronomeClick: Int
    public let thirtySecondNotesPerQuarter: Int

    public init(quarterPosition: Double = 0, numerator: Int = 4, denominator: Int = 4,
                clocksPerMetronomeClick: Int = 24, thirtySecondNotesPerQuarter: Int = 8) {
        self.quarterPosition = quarterPosition
        self.numerator = numerator
        self.denominator = denominator
        self.clocksPerMetronomeClick = clocksPerMetronomeClick
        self.thirtySecondNotesPerQuarter = thirtySecondNotesPerQuarter
    }

    fileprivate var quartersPerBeat: Double {
        32 / Double(denominator) / Double(thirtySecondNotesPerQuarter)
    }
}

public struct PianoBeat: Identifiable, Sendable, Hashable {
    public var id: Double { quarterPosition }
    public let time: Double
    public let quarterPosition: Double
    /// One-based measure and denominator-beat numbers. A signature change starts
    /// a new measure, truncating a partial previous measure when necessary.
    public let measure: Int
    public let beatInMeasure: Int
    public let numerator: Int
    public let denominator: Int
    public var isMeasure: Bool { beatInMeasure == 1 }
}

/// A compact score map. Beats are generated only for the requested time window;
/// very long files do not allocate one entry per beat at import or render time.
public struct PianoBeatGrid: Codable, Sendable, Hashable {
    private struct TempoSegment: Sendable, Hashable {
        let quarter: Double
        let seconds: Double
        let secondsPerQuarter: Double
    }
    private struct MeterSegment: Sendable, Hashable {
        let signature: PianoTimeSignature
        let firstMeasure: Int
    }

    public let duration: Double
    public let tempoChanges: [PianoTempoChange]
    public let timeSignatures: [PianoTimeSignature]
    private let tempos: [TempoSegment]
    private let meters: [MeterSegment]

    public init(duration: Double, tempoChanges: [PianoTempoChange] = [], timeSignatures: [PianoTimeSignature] = []) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        var normalizedTempos = [PianoTempoChange(quarterPosition: 0, microsecondsPerQuarter: 500_000)]
        let validTempos = tempoChanges.enumerated().filter {
            $0.element.quarterPosition.isFinite && $0.element.quarterPosition >= 0 && $0.element.microsecondsPerQuarter > 0
        }
        for (_, change) in validTempos.sorted(by: {
            $0.element.quarterPosition == $1.element.quarterPosition
                ? $0.offset < $1.offset : $0.element.quarterPosition < $1.element.quarterPosition
        }) {
            if normalizedTempos.last?.quarterPosition == change.quarterPosition { normalizedTempos[normalizedTempos.count - 1] = change }
            else { normalizedTempos.append(change) }
        }
        self.tempoChanges = normalizedTempos
        var tempoSegments: [TempoSegment] = []
        for change in normalizedTempos {
            let prior = tempoSegments.last
            let seconds = prior.map { $0.seconds + (change.quarterPosition - $0.quarter) * $0.secondsPerQuarter } ?? 0
            tempoSegments.append(TempoSegment(quarter: change.quarterPosition, seconds: seconds,
                                              secondsPerQuarter: Double(change.microsecondsPerQuarter) / 1_000_000))
        }
        tempos = tempoSegments

        var normalizedMeters = [PianoTimeSignature()]
        let validMeters = timeSignatures.enumerated().filter {
            let signature = $0.element
            return signature.quarterPosition.isFinite && signature.quarterPosition >= 0
                && (1...255).contains(signature.numerator) && signature.denominator > 0
                && signature.denominator <= 1 << 30 && signature.denominator.nonzeroBitCount == 1
                && (1...255).contains(signature.thirtySecondNotesPerQuarter)
        }
        for (_, signature) in validMeters.sorted(by: {
            $0.element.quarterPosition == $1.element.quarterPosition
                ? $0.offset < $1.offset : $0.element.quarterPosition < $1.element.quarterPosition
        }) {
            if normalizedMeters.last?.quarterPosition == signature.quarterPosition { normalizedMeters[normalizedMeters.count - 1] = signature }
            else { normalizedMeters.append(signature) }
        }
        self.timeSignatures = normalizedMeters
        var meterSegments: [MeterSegment] = []
        for signature in normalizedMeters {
            var measure = 1
            if let prior = meterSegments.last {
                let elapsed = (signature.quarterPosition - prior.signature.quarterPosition) / prior.signature.quartersPerBeat
                let elapsedMeasures = ceil(elapsed / Double(prior.signature.numerator) - 0.000000001)
                measure = Self.addingSaturated(prior.firstMeasure, Self.boundedInt(max(1, elapsedMeasures)))
            }
            meterSegments.append(MeterSegment(signature: signature, firstMeasure: measure))
        }
        meters = meterSegments
    }

    /// O(log(meter changes) + visible beats * log(tempo changes)). `limit` is
    /// capped at 4096 so even pathological signatures cannot flood a render frame.
    public func beats(in range: ClosedRange<Double>, limit: Int = 256) -> [PianoBeat] {
        let capacity = min(4096, max(0, limit))
        guard capacity > 0, range.lowerBound.isFinite, range.upperBound.isFinite else { return [] }
        let start = max(0, range.lowerBound)
        let end = min(duration, range.upperBound)
        guard start <= end else { return [] }
        let firstQuarter = quarter(at: start)
        let lastQuarter = quarter(at: end)
        var segmentIndex = lastIndex(in: meters, at: firstQuarter) { $0.signature.quarterPosition }
        var result: [PianoBeat] = []
        result.reserveCapacity(min(capacity, 256))
        while segmentIndex < meters.count && result.count < capacity {
            let segment = meters[segmentIndex]
            let signature = segment.signature
            guard signature.quarterPosition <= lastQuarter else { break }
            let nextQuarter = segmentIndex + 1 < meters.count ? meters[segmentIndex + 1].signature.quarterPosition : .infinity
            let unit = signature.quartersPerBeat
            var ordinal = max(0, ceil((max(firstQuarter, signature.quarterPosition) - signature.quarterPosition) / unit - 0.000000001))
            for _ in 0..<(capacity - result.count) {
                let position = signature.quarterPosition + ordinal * unit
                guard position <= lastQuarter + unit * 0.000000001,
                      position < nextQuarter - min(unit, 1) * 0.0000000001 else { break }
                let time = seconds(atQuarter: position)
                if time >= start - 0.000000001 && time <= end + 0.000000001 {
                    let measureOffset = Self.boundedInt(floor(ordinal / Double(signature.numerator)))
                    let beat = Int(ordinal.truncatingRemainder(dividingBy: Double(signature.numerator))) + 1
                    result.append(PianoBeat(time: time, quarterPosition: position,
                                            measure: Self.addingSaturated(segment.firstMeasure, measureOffset),
                                            beatInMeasure: beat, numerator: signature.numerator, denominator: signature.denominator))
                }
                let next = ordinal + 1
                guard next > ordinal else { break }
                ordinal = next
            }
            segmentIndex += 1
        }
        return result
    }

    public func seconds(atQuarter position: Double) -> Double {
        guard position.isFinite else { return 0 }
        let value = max(0, position)
        let segment = tempos[lastIndex(in: tempos, at: value) { $0.quarter }]
        return segment.seconds + (value - segment.quarter) * segment.secondsPerQuarter
    }

    private func quarter(at seconds: Double) -> Double {
        let segment = tempos[lastIndex(in: tempos, at: seconds) { $0.seconds }]
        return segment.quarter + (seconds - segment.seconds) / segment.secondsPerQuarter
    }

    private func lastIndex<T>(in values: [T], at position: Double, key: (T) -> Double) -> Int {
        var low = 0
        var high = values.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if key(values[middle]) <= position { low = middle } else { high = middle }
        }
        return low
    }

    private static func boundedInt(_ value: Double) -> Int {
        guard value.isFinite, value < Double(Int.max) else { return Int.max }
        return max(0, Int(value))
    }

    private static func addingSaturated(_ a: Int, _ b: Int) -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        return overflow ? Int.max : sum
    }

    private enum CodingKeys: String, CodingKey { case duration, tempoChanges, timeSignatures }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(duration: try values.decodeIfPresent(Double.self, forKey: .duration) ?? 0,
                  tempoChanges: try values.decodeIfPresent([PianoTempoChange].self, forKey: .tempoChanges) ?? [],
                  timeSignatures: try values.decodeIfPresent([PianoTimeSignature].self, forKey: .timeSignatures) ?? [])
    }
}
