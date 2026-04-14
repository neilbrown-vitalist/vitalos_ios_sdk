import Foundation

/// Splits a large data payload into MTU-sized packets, each prefixed with a 3-byte header.
public struct Packetizer: Sendable {

    public let mtuSize: Int
    private let payloadSize: Int

    public init(mtuSize: Int) {
        precondition(mtuSize >= PacketHeader.size, "MTU size must be >= header size (\(PacketHeader.size))")
        self.mtuSize = mtuSize
        self.payloadSize = mtuSize - PacketHeader.size
    }

    /// Creates a header-only ACK packet.
    public func createAckPacket(originalCommandId: Int, sequenceToAck: Int) -> Data {
        PacketHeader.createBytes(type: .ack, sequence: sequenceToAck, commandId: originalCommandId, isLastPacket: true)
    }

    /// Splits `data` into a list of MTU-sized packets, each with the correct header.
    public func chunk(type: PacketType, commandId: Int, data: Data) -> [Data] {
        if data.isEmpty {
            return [PacketHeader.createBytes(type: type, sequence: 0, commandId: commandId, isLastPacket: true)]
        }

        var packets: [Data] = []
        var sequenceNumber = 0
        var bytesSent = 0

        while bytesSent < data.count {
            let chunkSize = min(payloadSize, data.count - bytesSent)
            let isLastPacket = (bytesSent + chunkSize) == data.count

            let header = PacketHeader.createBytes(
                type: type,
                sequence: sequenceNumber & 31,
                commandId: commandId,
                isLastPacket: isLastPacket
            )

            var packet = Data(capacity: PacketHeader.size + chunkSize)
            packet.append(header)
            packet.append(data[data.startIndex + bytesSent ..< data.startIndex + bytesSent + chunkSize])
            packets.append(packet)

            bytesSent += chunkSize
            sequenceNumber += 1
        }

        return packets
    }
}
