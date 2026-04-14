import Foundation

/// A stateful handler for an incoming (Watch → App) data stream.
/// Register with ``StreamRouter/startStreamHandler(_:)``.
public protocol StreamHandler: StreamSession {
    func onStreamBegin() async
    func onDataChunk(sequenceNumber: Int, chunk: Data) async
    func onStreamEnd(_ command: EndStream) async -> Bool
}
