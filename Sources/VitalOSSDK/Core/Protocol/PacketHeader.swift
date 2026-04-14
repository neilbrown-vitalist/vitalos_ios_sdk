import Foundation

/// The 3-byte header prepended to every BLE packet.
///
/// Layout:
/// - Byte 0: `[isLastPacketOfMessage (1 bit)][Type (2 bits)][Sequence (5 bits)]`
/// - Bytes 1–2: CommandId (little-endian UInt16)
public struct PacketHeader: Equatable, Sendable {
    public static let size = 3

    public let sequenceNumber: Int
    public let commandId: Int
    public let type: PacketType
    public let isLastPacketOfMessage: Bool

    public init(sequenceNumber: Int, commandId: Int, type: PacketType, isLastPacketOfMessage: Bool) {
        self.sequenceNumber = sequenceNumber
        self.commandId = commandId
        self.type = type
        self.isLastPacketOfMessage = isLastPacketOfMessage
    }

    /// Parses a header from the first 3 bytes of `packet`.
    public static func fromBytes(_ packet: Data) -> PacketHeader {
        precondition(packet.count >= size, "Packet too short to contain a header (\(packet.count) < \(size))")
        let headerByte = Int(packet[packet.startIndex])
        let sequenceNumber = headerByte & 0x1F
        guard let type = PacketType(rawValue: UInt8((headerByte >> 5) & 0x03)) else {
            fatalError("Unknown PacketType value: \((headerByte >> 5) & 0x03)")
        }
        let isLast = (headerByte & 0x80) != 0
        let commandId = Int(packet[packet.startIndex + 1]) | (Int(packet[packet.startIndex + 2]) << 8)
        return PacketHeader(sequenceNumber: sequenceNumber, commandId: commandId, type: type, isLastPacketOfMessage: isLast)
    }

    /// Creates 3 raw header bytes.
    public static func createBytes(type: PacketType, sequence: Int, commandId: Int, isLastPacket: Bool) -> Data {
        precondition(sequence <= 31, "Sequence number cannot exceed 31 (5 bits)")
        var headerByte = sequence & 0x1F
        headerByte |= (Int(type.rawValue) & 0x03) << 5
        if isLastPacket { headerByte |= 0x80 }
        var bytes = Data(count: size)
        bytes[0] = UInt8(headerByte)
        bytes[1] = UInt8(commandId & 0xFF)
        bytes[2] = UInt8((commandId >> 8) & 0xFF)
        return bytes
    }
}
