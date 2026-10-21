#if canImport(CoreMIDI)
import CoreMIDI
import Testing
@testable import PianoLink

struct MIDIPacketReaderTests {
    @Test func copiesAllFortyPacketsFromOriginalListStorage() throws {
        let expected: [MIDIPacketBytes] = (0..<40).map { (index: Int) -> MIDIPacketBytes in
            let bytes: [UInt8] = [0x90, UInt8(index + 30), UInt8(index + 60)]
            return MIDIPacketBytes(bytes: bytes, hostTimestamp: MIDITimeStamp(index + 1))
        }
        // The helper frees the callback storage before this comparison; only owned
        // bytes and scalar timestamps may escape the packet reader.
        let actual = try copyPacketFixture(expected)
        #expect(actual.count == 40)
        #expect(actual == expected)
    }

    @Test func copiesPayloadLargerThanImportedFixedSizeDataTuple() throws {
        let payload = (0..<600).map { UInt8($0 % 128) }
        let expected = [
            MIDIPacketBytes(bytes: payload, hostTimestamp: 1),
            MIDIPacketBytes(bytes: [0x80, 60, 0], hostTimestamp: 2)
        ]
        let actual = try copyPacketFixture(expected)
        #expect(actual == expected)
    }

    @Test func emptyListHasNoPackets() throws {
        #expect(try copyPacketFixture([]).isEmpty)
    }

    private func copyPacketFixture(_ packets: [MIDIPacketBytes]) throws -> [MIDIPacketBytes] {
        let capacity = 32_768
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: capacity, alignment: MemoryLayout<MIDIPacketList>.alignment
        )
        defer { storage.deallocate() }
        let packetList = storage.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var currentPacket = MIDIPacketListInit(packetList)
        for packet in packets {
            let next = packet.bytes.withUnsafeBufferPointer { bytes in
                MIDIPacketListAdd(packetList, capacity, currentPacket, packet.hostTimestamp,
                                  bytes.count, bytes.baseAddress!)
            }
            currentPacket = next
        }
        #expect(packetList.pointee.numPackets == packets.count)
        return MIDIPacketReader.copyPackets(from: UnsafePointer(packetList))
    }
}
#endif
