import Foundation

/// A rebased clock measured against monotonic host uptime. Position is computed, never frame-accumulated.
public struct PlaybackClock: Sendable {
    public private(set) var isPlaying: Bool = false
    public private(set) var rate: Double
    private var anchorPosition: Double
    private var anchorHostTime: Double

    public init(position: Double = 0, rate: Double = 1, now: Double = ProcessInfo.processInfo.systemUptime) {
        self.anchorPosition = position.isFinite ? max(0, position) : 0
        self.rate = rate.isFinite && rate > 0 ? rate : 1
        self.anchorHostTime = now
    }

    public func position(at hostTime: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        guard isPlaying, hostTime.isFinite else { return anchorPosition }
        return anchorPosition + max(0, hostTime - anchorHostTime) * rate
    }

    public mutating func play(at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard !isPlaying, hostTime.isFinite else { return }
        anchorHostTime = hostTime
        isPlaying = true
    }

    public mutating func pause(at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard hostTime.isFinite else { return }
        anchorPosition = position(at: hostTime)
        anchorHostTime = hostTime
        isPlaying = false
    }

    public mutating func seek(to position: Double, at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard position.isFinite, hostTime.isFinite else { return }
        anchorPosition = max(0, position)
        anchorHostTime = hostTime
    }

    public mutating func setRate(_ rate: Double, at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard rate.isFinite, rate > 0, hostTime.isFinite else { return }
        anchorPosition = position(at: hostTime)
        anchorHostTime = hostTime
        self.rate = rate
    }

    public mutating func stop(at hostTime: Double = ProcessInfo.processInfo.systemUptime) {
        pause(at: hostTime)
        seek(to: 0, at: hostTime)
    }
}
