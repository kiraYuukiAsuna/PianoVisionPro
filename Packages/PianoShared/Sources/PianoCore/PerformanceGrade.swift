import Foundation

/// Feedback for matched notes; never controls acceptance. Times are host seconds
/// so a frozen wait-mode clock cannot hide late strikes or shorten real holds.
public struct PerformanceGrade: Sendable {
    private struct Attempt: Sendable {
        let pitch: Int
        let onsetAt: Double
        let releaseAt: Double
        let onsetQuality: Double
        var releaseQuality: Double?
        var committed: Bool
        var provisional = false
        var scoredQuality: Double?
    }
    private var attempts: [Int: Attempt] = [:]
    private var owners: [Int: Int] = [:]
    private var pending: Set<Int> = []
    private var evaluatedIDs: Set<Int> = []
    private var qualitySum = 0.0
    public private(set) var evaluatedNoteCount = 0

    public init() {}
    public var timingPercentage: Double? {
        evaluatedNoteCount > 0 ? min(100, max(0, qualitySum / Double(evaluatedNoteCount) * 100)) : nil
    }

    public static func completionPercentage(correct: Int, wrong: Int, missed: Int) -> Double {
        let correct = Double(max(0, correct))
        let total = correct + Double(max(0, wrong)) + Double(max(0, missed))
        return total > 0 ? correct / total * 100 : 0
    }

    /// 80 ms earns full credit; 500 ms earns zero credit.
    public static func edgeQuality(errorSeconds: Double) -> Double {
        guard errorSeconds.isFinite else { return 0 }
        return min(1, max(0, (0.5 - abs(errorSeconds)) / 0.42))
    }

    public mutating func noteOn(id: Int, pitch: Int, performedAt: Double,
                                targetAt: Double, duration: Double, committed: Bool) {
        guard performedAt.isFinite, targetAt.isFinite, duration.isFinite, duration >= 0,
              (0...127).contains(pitch), !evaluatedIDs.contains(id), attempts[id] == nil,
              owners[pitch] == nil else { return }
        let onset = Self.edgeQuality(errorSeconds: performedAt - targetAt)
        attempts[id] = Attempt(pitch: pitch, onsetAt: performedAt, releaseAt: targetAt + duration,
                               onsetQuality: onset, releaseQuality: duration == 0 ? onset : nil,
                               committed: committed)
        if duration > 0 { owners[pitch] = id }
        if !committed { pending.insert(id) }
        settle(id)
    }

    public mutating func noteOff(pitch: Int, at time: Double) {
        guard time.isFinite, let id = owners[pitch], var attempt = attempts[id], time >= attempt.onsetAt else { return }
        owners.removeValue(forKey: pitch)
        attempt.releaseQuality = Self.edgeQuality(errorSeconds: time - attempt.releaseAt)
        attempt.provisional = false
        attempts[id] = attempt
        settle(id)
    }

    public mutating func commit(noteIDs: Set<Int>) {
        for id in noteIDs where pending.contains(id) {
            pending.remove(id)
            attempts[id]?.committed = true
            settle(id)
        }
    }

    /// Future inputs can be revoked, while current arpeggios retain released notes.
    public mutating func retainPending(validNoteIDs: Set<Int>) {
        for id in pending.subtracting(validNoteIDs) { discard(id) }
    }

    /// A never-released key cannot leave its good onset permanently ungraded.
    public mutating func advance(to time: Double) {
        guard time.isFinite else { return }
        for id in Array(owners.values) {
            guard var attempt = attempts[id], !attempt.provisional, time >= attempt.releaseAt + 0.5 else { continue }
            attempt.releaseQuality = 0
            attempt.provisional = true
            attempts[id] = attempt
            settle(id)
        }
    }

    public mutating func cancelHeld(pitch: Int) {
        if let id = owners[pitch] { discard(id) }
    }

    /// Pause and source resets discard incomplete measurements, not finished samples.
    public mutating func interrupt() {
        for id in Set(owners.values).union(pending) { discard(id) }
    }

    private mutating func settle(_ id: Int) {
        guard var attempt = attempts[id], attempt.committed, let release = attempt.releaseQuality else { return }
        let quality = (attempt.onsetQuality + release) / 2
        qualitySum += quality - (attempt.scoredQuality ?? 0)
        if evaluatedIDs.insert(id).inserted { evaluatedNoteCount += 1 }
        if attempt.provisional {
            // Keep physical ownership so a delayed, timestamp-correct release
            // can repair a provisional timeout without adding a second sample.
            attempt.scoredQuality = quality
            attempts[id] = attempt
        } else {
            discard(id)
        }
    }

    private mutating func discard(_ id: Int) {
        if let attempt = attempts.removeValue(forKey: id), owners[attempt.pitch] == id {
            owners.removeValue(forKey: attempt.pitch)
        }
        pending.remove(id)
    }
}
