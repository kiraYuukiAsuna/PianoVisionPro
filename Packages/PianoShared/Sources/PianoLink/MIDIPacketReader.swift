#if canImport(CoreMIDI)
import CoreMIDI

/// Owned MIDI callback data that can safely cross a queue boundary.
public struct MIDIPacketBytes: Equatable, Sendable {
    public let bytes: [UInt8]
    public let hostTimestamp: MIDITimeStamp

    public init(bytes: [UInt8], hostTimestamp: MIDITimeStamp) {
        self.bytes = bytes
        self.hostTimestamp = hostTimestamp
    }
}

public enum MIDIPacketReader {
    /// Copies the entire variable-length list before its callback-owned storage expires.
    public static func copyPackets(from packetList: UnsafePointer<MIDIPacketList>) -> [MIDIPacketBytes] {
        let packetOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet)!
        let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data)!
        // Taking a pointer to `packetList.pointee.packet` would copy the fixed-size
        // imported struct and lose every packet (or payload byte) beyond that copy.
        var packet = UnsafeRawPointer(packetList).advanced(by: packetOffset)
            .assumingMemoryBound(to: MIDIPacket.self)
        var packets: [MIDIPacketBytes] = []
        packets.reserveCapacity(Int(packetList.pointee.numPackets))
        for _ in 0..<packetList.pointee.numPackets {
            let bytes = UnsafeRawPointer(packet).advanced(by: dataOffset)
                .assumingMemoryBound(to: UInt8.self)
            packets.append(MIDIPacketBytes(
                bytes: Array(UnsafeBufferPointer(start: bytes, count: Int(packet.pointee.length))),
                hostTimestamp: packet.pointee.timeStamp
            ))
            packet = UnsafePointer(MIDIPacketNext(packet))
        }
        return packets
    }
}
#endif
