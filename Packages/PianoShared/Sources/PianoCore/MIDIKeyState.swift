import Foundation

/// Physical key state and sounding state are distinct when CC64 sustain is held.
/// Channel state remains independent even when two channels use the same pitch.
public struct MIDIKeyState: Sendable {
    private struct ChannelState: Sendable {
        var pressed: Set<Int> = []
        var sustained: Set<Int> = []
        var sustain = false
    }

    private var channels: [Int: ChannelState] = [:]

    public init() {}

    public var pressedPitches: Set<Int> {
        channels.values.reduce(into: Set<Int>()) { $0.formUnion($1.pressed) }
    }

    public var soundingPitches: Set<Int> {
        channels.values.reduce(into: Set<Int>()) {
            $0.formUnion($1.pressed)
            $0.formUnion($1.sustained)
        }
    }

    public func pressedPitches(channel: Int) -> Set<Int> { channels[channel]?.pressed ?? [] }
    public func soundingPitches(channel: Int) -> Set<Int> {
        (channels[channel]?.pressed ?? []).union(channels[channel]?.sustained ?? [])
    }
    public func isSustainDown(channel: Int) -> Bool { channels[channel]?.sustain ?? false }

    public mutating func noteOn(pitch: Int, velocity: Int, channel: Int = 0) {
        guard (0...127).contains(pitch), (0...15).contains(channel) else { return }
        guard velocity > 0 else { noteOff(pitch: pitch, channel: channel); return }
        channels[channel, default: ChannelState()].pressed.insert(pitch)
        channels[channel, default: ChannelState()].sustained.remove(pitch)
    }

    public mutating func noteOff(pitch: Int, channel: Int = 0) {
        guard var state = channels[channel] else { return }
        let wasPressed = state.pressed.remove(pitch) != nil
        if wasPressed && state.sustain { state.sustained.insert(pitch) }
        channels[channel] = state
    }

    public mutating func controlChange(controller: Int, value: Int, channel: Int = 0) {
        guard (0...15).contains(channel) else { return }
        var state = channels[channel, default: ChannelState()]
        switch controller {
        case 64:
            state.sustain = value >= 64
            if !state.sustain { state.sustained.removeAll() }
        case 120: // All Sound Off bypasses the sustain pedal.
            state.pressed.removeAll()
            state.sustained.removeAll()
        case 121: // Reset All Controllers releases sustain but preserves physically held keys.
            state.sustain = false
            state.sustained.removeAll()
        case 123...127: // Channel mode changes also imply All Notes Off and observe sustain.
            if state.sustain { state.sustained.formUnion(state.pressed) }
            state.pressed.removeAll()
        default:
            break
        }
        channels[channel] = state
    }

    /// Call when the bridge disconnects, the source changes, or the app deactivates.
    public mutating func reset() { channels.removeAll() }
}
