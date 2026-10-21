import Foundation
import Testing
@testable import PianoLink

struct MIDIByteDecoderTests {
    @Test func runningStatusSurvivesPacketBoundariesAndRealtimeBytes() {
        var decoder = MIDIByteDecoder()
        #expect(decoder.decode([0x92, 60], timestamp: 1).isEmpty)
        let events = decoder.decode([100, 64, 0xF8, 90, 67, 0], timestamp: 2)
        #expect(events.map(\.kind) == [.noteOn, .noteOn, .noteOff])
        #expect(events.map(\.note) == [60, 64, 67])
        #expect(events.allSatisfy { $0.channel == 2 })
        #expect(events.map(\.velocity) == [100, 90, 0])
    }

    @Test func controllerAndExplicitNoteOffEventsKeepChannelAndValues() {
        var decoder = MIDIByteDecoder()
        let events = decoder.decode([0xBF, 64, 127, 64, 0, 120, 0, 123, 0, 0x8F, 60, 42], timestamp: 3)
        #expect(events.map(\.kind) == [.controlChange, .controlChange, .allNotesOff, .allNotesOff, .noteOff])
        #expect(events.map(\.controller) == [64, 64, 120, 123, 0])
        #expect(events.allSatisfy { $0.channel == 15 && $0.timestamp == 3 })
        #expect(events.last?.velocity == 42)
    }

    @Test func systemMessagesCancelRunningStatusAndOtherChannelMessagesConsumeCorrectLength() {
        var decoder = MIDIByteDecoder()
        _ = decoder.decode([0x90, 60, 100, 0xF0, 1, 2, 0xF8, 3, 0xF7], timestamp: 1)
        #expect(decoder.decode([60, 127], timestamp: 2).isEmpty)
        let events = decoder.decode([0xC0, 5, 7, 0xD0, 127, 0xE0, 1, 2, 0x91, 72, 110,
                                     0xF2, 1, 2, 72, 0, 0x81, 72, 0], timestamp: 3)
        #expect(events.map(\.kind) == [.noteOn, .noteOff])
        #expect(events.allSatisfy { $0.note == 72 && $0.channel == 1 })
    }

    @Test func timestampUsesDataPacketForRunningStatusMessage() {
        var decoder = MIDIByteDecoder()
        _ = decoder.decode([0x90, 60, 100], timestamp: 10)
        let next = decoder.decode([62, 100], timestamp: 11)
        #expect(next.first?.timestamp == 11)
    }
}
