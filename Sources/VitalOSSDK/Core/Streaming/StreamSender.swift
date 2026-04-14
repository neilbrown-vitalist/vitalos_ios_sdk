import Foundation

/// A stateful handler for an outgoing (App → Watch) data stream.
/// Register with ``StreamRouter/startStreamSender(_:)``.
public protocol StreamSender: StreamSession {
    func start(listener: StreamSenderCompletionListener) async
    func onAckReceived(sequenceNumber: Int)
}

/// Implemented by ``StreamRouter`` to be notified when a ``StreamSender`` finishes.
public protocol StreamSenderCompletionListener: AnyObject {
    func onStreamSenderComplete(streamId: Int, success: Bool, errorMessage: String?)
}
