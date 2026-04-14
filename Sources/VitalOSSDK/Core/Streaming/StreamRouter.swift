import Foundation

/// Manages the lifecycle of all active streaming sessions.
public protocol StreamRouter: AnyObject, StreamSenderCompletionListener {
    func startStreamHandler(_ handler: StreamHandler) async throws
    func startStreamSender(_ sender: StreamSender) async
    func onDataChunk(_ chunk: StreamDataChunk)
    func onStreamEnd(_ command: EndStream)
    func onStreamCancel(_ command: CancelStream)
    func onAckReceived(_ ack: StreamDataChunkAck)
    func abortStream(streamId: Int, reason: CancelReason, message: String)
    func sendDataTransportAck(streamId: Int, sequenceNumber: Int)
    func cleanupAllStreams()
    func dispose()
}
