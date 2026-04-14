import Foundation
import os

/// The result of a successful reassembly.
public struct ReassemblyResult: Sendable {
    public let header: PacketHeader
    public let payload: Data
}

/// Reassembles streams of packets into complete messages, per command ID.
/// Handles interleaved chunks from different commands via per-commandId sessions.
public final class PacketReassembler: @unchecked Sendable {

    private let logger = Logger(subsystem: "co.vitalos.sdk", category: "PacketReassembler")
    private let sessionTimeoutSeconds: TimeInterval
    private var sessions: [Int: ReassemblySession] = [:]
    private var gcTask: Task<Void, Never>?

    public init(sessionTimeoutSeconds: TimeInterval = 30, gcIntervalSeconds: TimeInterval = 15) {
        self.sessionTimeoutSeconds = sessionTimeoutSeconds
        gcTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(gcIntervalSeconds * 1_000_000_000))
                self?.collectGarbage()
            }
        }
    }

    /// Process a single raw incoming packet.
    /// Returns a ``ReassemblyResult`` when the final packet of a message is received, else `nil`.
    public func processPacket(_ packet: Data) -> ReassemblyResult? {
        guard packet.count >= PacketHeader.size else {
            logger.warning("Received invalid packet: too short (\(packet.count) bytes)")
            return nil
        }

        let header = PacketHeader.fromBytes(packet)

        if header.type == .ack && packet.count == PacketHeader.size {
            logger.debug("Received ACK for command 0x\(String(header.commandId, radix: 16))")
            return ReassemblyResult(header: header, payload: Data())
        }

        if header.sequenceNumber == 0 && sessions[header.commandId] != nil {
            logger.info("Received Seq 0 for existing session \(header.commandId). Resetting.")
            sessions.removeValue(forKey: header.commandId)
        }

        let session = sessions[header.commandId] ?? {
            let s = ReassemblySession()
            sessions[header.commandId] = s
            return s
        }()

        let payload = packet.suffix(from: packet.startIndex + PacketHeader.size)

        do {
            try session.addChunk(Data(payload), sequence: header.sequenceNumber)
        } catch {
            logger.error("Reassembly error for command \(header.commandId): \(error.localizedDescription). Discarding session.")
            sessions.removeValue(forKey: header.commandId)
            return nil
        }

        if header.isLastPacketOfMessage {
            let fullPayload = session.assemble()
            sessions.removeValue(forKey: header.commandId)
            return ReassemblyResult(header: header, payload: fullPayload)
        }

        return nil
    }

    private func collectGarbage() {
        let staleKeys = sessions.filter { $0.value.isStale(timeoutSeconds: sessionTimeoutSeconds) }.map(\.key)
        if !staleKeys.isEmpty {
            logger.warning("Cleaning up stale reassembly sessions: \(staleKeys)")
            for key in staleKeys { sessions.removeValue(forKey: key) }
        }
    }

    public func dispose() {
        gcTask?.cancel()
        gcTask = nil
        sessions.removeAll()
    }
}

// MARK: - ReassemblySession

private final class ReassemblySession {
    private var buffer: [Data] = []
    var lastUpdateTime = Date()
    var nextExpectedSequence = 0

    func addChunk(_ chunk: Data, sequence: Int) throws {
        if sequence < nextExpectedSequence {
            return // duplicate — ignore
        }
        if sequence > nextExpectedSequence {
            throw VitalOsError.unknown("Out-of-order packet. Expected \(nextExpectedSequence), got \(sequence)")
        }
        buffer.append(chunk)
        lastUpdateTime = Date()
        nextExpectedSequence = (nextExpectedSequence + 1) % 32
    }

    func assemble() -> Data {
        var result = Data(capacity: buffer.reduce(0) { $0 + $1.count })
        for chunk in buffer { result.append(chunk) }
        return result
    }

    func isStale(timeoutSeconds: TimeInterval) -> Bool {
        Date().timeIntervalSince(lastUpdateTime) > timeoutSeconds
    }
}
