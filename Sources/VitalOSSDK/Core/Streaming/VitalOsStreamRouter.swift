import Foundation
import os

/// Manages the lifecycle of all active streaming sessions with timeout support.
public final class VitalOsStreamRouter: StreamRouter, @unchecked Sendable {

    private let logger = Logger(subsystem: "co.vitalos.sdk", category: "VitalOsStreamRouter")
    private let transport: VitalOsTransportLayer

    private var activeSessions: [Int: StreamSession] = [:]
    private var timeoutTasks: [Int: Task<Void, Never>] = [:]
    private var lastChunkTimestamps: [Int: Date] = [:]

    private static let incomingIdleTimeoutSeconds: TimeInterval = 15
    private static let outgoingTotalTimeoutSeconds: TimeInterval = 600

    public init(transport: VitalOsTransportLayer) {
        self.transport = transport
    }

    // MARK: - StreamRouter API

    public func startStreamHandler(_ handler: StreamHandler) async throws {
        let streamId = handler.streamId
        guard activeSessions[streamId] == nil else {
            throw VitalOsError.unknown("Stream \(streamId) already active")
        }
        logger.info("Starting incoming stream handler for ID: \(streamId)")
        activeSessions[streamId] = handler
        do {
            await handler.onStreamBegin()
            startIncomingTimeout(streamId: streamId)
        } catch {
            logger.error("Stream handler \(streamId) failed onStreamBegin: \(error.localizedDescription)")
            abortStream(streamId: streamId, reason: .streamInternalError, message: error.localizedDescription)
        }
    }

    public func startStreamSender(_ sender: StreamSender) async {
        let streamId = sender.streamId
        guard activeSessions[streamId] == nil else {
            logger.warning("Stream \(streamId) already active")
            return
        }
        logger.info("Starting outgoing stream sender for ID: \(streamId)")
        activeSessions[streamId] = sender
        startOutgoingTimeout(streamId: streamId)
        Task { await sender.start(listener: self) }
    }

    public func onStreamSenderComplete(streamId: Int, success: Bool, errorMessage: String?) {
        if success {
            logger.info("Stream sender \(streamId) completed successfully")
            cleanupStream(streamId: streamId, reason: .reasonUnknown, notify: false)
        } else {
            logger.warning("Stream sender \(streamId) failed: \(errorMessage ?? "unknown")")
            abortStream(streamId: streamId, reason: .streamInternalError, message: errorMessage ?? "Sender failed")
        }
    }

    public func onDataChunk(_ chunk: StreamDataChunk) {
        guard let session = activeSessions[Int(chunk.streamID)] as? StreamHandler else {
            logger.warning("Received chunk for unknown/invalid stream: \(chunk.streamID)")
            return
        }
        resetIncomingTimeout(streamId: Int(chunk.streamID))
        Task { await session.onDataChunk(sequenceNumber: Int(chunk.sequenceNumber), chunk: chunk.data) }
    }

    public func onStreamEnd(_ command: EndStream) {
        let streamId = Int(command.streamID)
        logger.info("Received EndStream for \(streamId)")
        guard let session = activeSessions[streamId] as? StreamHandler else {
            logger.warning("Received EndStream for unknown stream: \(streamId)")
            stopTimeout(streamId: streamId)
            return
        }
        Task {
            let success = await session.onStreamEnd(command)
            if success {
                self.cleanupStream(streamId: streamId, reason: .reasonUnknown, notify: false)
            } else {
                self.abortStream(streamId: streamId, reason: .streamInternalError, message: "Stream validation failed")
            }
        }
    }

    public func onStreamCancel(_ command: CancelStream) {
        logger.info("Received remote CancelStream for \(command.streamID): \(String(describing: command.reasonCode))")
        cleanupStream(streamId: Int(command.streamID), reason: command.reasonCode)
    }

    public func onAckReceived(_ ack: StreamDataChunkAck) {
        guard let session = activeSessions[Int(ack.streamID)] as? StreamSender else {
            logger.warning("Received ACK for unknown/invalid stream: \(ack.streamID)")
            return
        }
        session.onAckReceived(sequenceNumber: Int(ack.sequenceNumber))
    }

    public func abortStream(streamId: Int, reason: CancelReason, message: String) {
        logger.warning("Aborting stream \(streamId) locally. Reason: \(String(describing: reason)), Msg: \(message)")
        if activeSessions[streamId] != nil {
            var cancelCommand = CancelStream()
            cancelCommand.streamID = Int32(streamId)
            cancelCommand.reasonCode = reason
            cancelCommand.reasonMessage = message
            Task {
                do {
                    try await transport.send(type: .command, commandId: VitalOsCommand.cancelStream.rawValue, payload: cancelCommand.serializedData())
                } catch {
                    self.logger.warning("Failed to send CancelStream for \(streamId): \(error.localizedDescription)")
                }
            }
        }
        cleanupStream(streamId: streamId, reason: reason)
    }

    public func sendDataTransportAck(streamId: Int, sequenceNumber: Int) {
        var ack = StreamDataChunkAck()
        ack.streamID = Int32(streamId)
        ack.sequenceNumber = Int32(sequenceNumber)
        Task {
            do {
                try await transport.send(type: .command, commandId: VitalOsCommand.sendDataChunkAck.rawValue, payload: ack.serializedData())
            } catch {
                self.logger.warning("Failed to send data chunk ACK for stream \(streamId): \(error.localizedDescription)")
            }
        }
    }

    public func cleanupAllStreams() {
        logger.info("Cleaning up all active streams")
        for streamId in activeSessions.keys {
            cleanupStream(streamId: streamId, reason: .disconnected)
        }
    }

    public func dispose() {
        cleanupAllStreams()
        for task in timeoutTasks.values { task.cancel() }
        timeoutTasks.removeAll()
        lastChunkTimestamps.removeAll()
        activeSessions.removeAll()
    }

    // MARK: - Internals

    private func cleanupStream(streamId: Int, reason: CancelReason, notify: Bool = true) {
        stopTimeout(streamId: streamId)
        let session = activeSessions.removeValue(forKey: streamId)
        if notify { session?.onStreamCancel(reason: reason) }
    }

    private func startIncomingTimeout(streamId: Int) {
        stopTimeout(streamId: streamId)
        lastChunkTimestamps[streamId] = Date()
        timeoutTasks[streamId] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
                guard let self, let lastTime = self.lastChunkTimestamps[streamId] else { break }
                if Date().timeIntervalSince(lastTime) > Self.incomingIdleTimeoutSeconds {
                    self.abortStream(streamId: streamId, reason: .timeout, message: "Stream timed out")
                    break
                }
            }
        }
    }

    private func startOutgoingTimeout(streamId: Int) {
        stopTimeout(streamId: streamId)
        timeoutTasks[streamId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.outgoingTotalTimeoutSeconds * 1_000_000_000))
            guard let self, self.activeSessions[streamId] != nil else { return }
            self.abortStream(streamId: streamId, reason: .timeout, message: "Total duration timeout")
        }
    }

    private func resetIncomingTimeout(streamId: Int) {
        if lastChunkTimestamps[streamId] != nil {
            lastChunkTimestamps[streamId] = Date()
        }
    }

    private func stopTimeout(streamId: Int) {
        timeoutTasks.removeValue(forKey: streamId)?.cancel()
        lastChunkTimestamps.removeValue(forKey: streamId)
    }
}
