import Foundation
import os

/// Wraps a ``BleTransport`` to provide the VitalOS protocol transport layer.
///
/// Responsibilities:
/// - Subscribes to raw BLE bytes, feeds them into ``PacketReassembler``, emits complete messages.
/// - Serialises all outgoing sends via an actor-based queue (prevents packet interleaving).
/// - Sends protocol-level ACKs for every 5th command packet or the last packet of a message.
public final class VitalOsTransportLayer: @unchecked Sendable {

    private let logger = Logger(subsystem: "co.vitalos.sdk", category: "VitalOsTransportLayer")
    private let bleTransport: BleTransport
    private let reassembler: PacketReassembler

    private let messageContinuation: AsyncStream<ReassemblyResult>.Continuation
    public let onMessageReceived: AsyncStream<ReassemblyResult>

    private var receiveTask: Task<Void, Never>?

    private let sendQueue = SendQueue()

    public var currentMtu: Int { bleTransport.mtu }

    public init(bleTransport: BleTransport) {
        self.bleTransport = bleTransport
        self.reassembler = PacketReassembler()
        (onMessageReceived, messageContinuation) = AsyncStream<ReassemblyResult>.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    public func startListening() async throws {
        guard receiveTask == nil else {
            logger.debug("Already listening, skipping startListening()")
            return
        }

        try await bleTransport.enableIndications()

        receiveTask = Task { [weak self] in
            guard let self else { return }
            for await rawBytes in self.bleTransport.onDataReceived {
                self.onRawBytesReceived(rawBytes)
            }
        }

        logger.info("Started listening on BLE transport")
    }

    public func stopListening() async {
        logger.debug("Stopping transport listener")
        receiveTask?.cancel()
        receiveTask = nil

        do {
            try await bleTransport.disableIndications()
        } catch {
            logger.warning("Could not disable indications (device may be disconnected): \(error.localizedDescription)")
        }
    }

    private func onRawBytesReceived(_ data: Data) {
        logger.trace("RX: \(data.count) bytes")

        if data.count >= PacketHeader.size {
            let header = PacketHeader.fromBytes(data)
            if header.type == .command &&
                (header.sequenceNumber % 5 == 0 || header.isLastPacketOfMessage) {
                sendTransportAck(commandId: header.commandId, sequenceNumber: header.sequenceNumber)
            }
        }

        if let result = reassembler.processPacket(data) {
            logger.debug("Reassembled message: type=\(String(describing: result.header.type)), id=0x\(String(result.header.commandId, radix: 16)), size=\(result.payload.count)")
            messageContinuation.yield(result)
        }
    }

    public func send(type: PacketType, commandId: Int, payload: Data) async throws {
        try await sendQueue.enqueue { [self] in
            self.logger.debug("TX: type=\(String(describing: type)), id=0x\(String(commandId, radix: 16)), size=\(payload.count)")

            let packetizer = Packetizer(mtuSize: self.currentMtu - 3)
            let packets = packetizer.chunk(type: type, commandId: commandId, data: payload)
            for packet in packets {
                try await self.bleTransport.write(packet)
            }
        }
    }

    public func sendTransportAck(commandId: Int, sequenceNumber: Int) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendQueue.enqueue {
                    self.logger.trace("TX: ACK for id=0x\(String(commandId, radix: 16)), seq=\(sequenceNumber)")
                    let packetizer = Packetizer(mtuSize: self.currentMtu - 3)
                    let ackPacket = packetizer.createAckPacket(originalCommandId: commandId, sequenceToAck: sequenceNumber)
                    try await self.bleTransport.write(ackPacket)
                }
            } catch {
                self.logger.warning("Failed to send transport ACK for 0x\(String(commandId, radix: 16)): \(error.localizedDescription)")
            }
        }
    }

    public func dispose() {
        receiveTask?.cancel()
        receiveTask = nil
        messageContinuation.finish()
        reassembler.dispose()
        bleTransport.close()
    }
}

// MARK: - Serial Send Queue

/// An actor that serialises send operations to prevent packet interleaving on the BLE link.
private actor SendQueue {
    func enqueue(_ block: @Sendable () async throws -> Void) async throws {
        try await block()
    }
}
