import Foundation
import SwiftProtobuf

/// Manages app-initiated commands and matches them with device responses.
public protocol RequestManager: AnyObject {
    var currentMtu: Int { get }

    /// Sends `command` and suspends until the device responds with a `CommandResponse`.
    func sendRequestAndWait(
        commandId: Int,
        command: SwiftProtobuf.Message,
        timeoutMs: UInt64
    ) async throws -> CommandResponse

    /// Sends a command without waiting for a response.
    func sendRequest(commandId: Int, command: SwiftProtobuf.Message) async throws

    /// Sends a streaming data packet.
    func sendStreamData(commandId: Int, data: SwiftProtobuf.Message) async throws

    /// Called by ``CommandRouter`` when a response packet arrives.
    func onResponseReceived(commandId: Int, response: CommandResponse)

    func dispose()
}

public extension RequestManager {
    func sendRequestAndWait(
        commandId: Int,
        command: SwiftProtobuf.Message,
        timeoutMs: UInt64 = 15_000
    ) async throws -> CommandResponse {
        try await sendRequestAndWait(commandId: commandId, command: command, timeoutMs: timeoutMs)
    }
}
