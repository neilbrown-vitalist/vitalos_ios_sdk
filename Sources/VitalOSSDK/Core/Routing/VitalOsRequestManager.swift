import Foundation
import SwiftProtobuf
import os

/// Sends app-initiated commands and matches incoming `CommandResponse` packets
/// to their corresponding pending request.
public final class VitalOsRequestManager: RequestManager, @unchecked Sendable {

    private let logger = Logger(subsystem: "co.vitalos.sdk", category: "VitalOsRequestManager")
    private let transport: VitalOsTransportLayer
    private var pendingRequests: [Int: CheckedContinuation<CommandResponse, Error>] = [:]
    private let lock = NSLock()

    public var currentMtu: Int { transport.currentMtu }

    public init(transport: VitalOsTransportLayer) {
        self.transport = transport
    }

    public func sendRequestAndWait(
        commandId: Int,
        command: SwiftProtobuf.Message,
        timeoutMs: UInt64
    ) async throws -> CommandResponse {
        lock.lock()
        guard pendingRequests[commandId] == nil else {
            lock.unlock()
            throw VitalOsError.unknown("Request 0x\(String(commandId, radix: 16)) already pending")
        }
        lock.unlock()

        return try await withThrowingTaskGroup(of: CommandResponse.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { [self] (continuation: CheckedContinuation<CommandResponse, Error>) in
                    lock.lock()
                    pendingRequests[commandId] = continuation
                    lock.unlock()

                    Task {
                        do {
                            try await self.sendRequest(commandId: commandId, command: command)
                        } catch {
                            self.lock.lock()
                            let cont = self.pendingRequests.removeValue(forKey: commandId)
                            self.lock.unlock()
                            cont?.resume(throwing: error)
                        }
                    }
                }
            }

            group.addTask {
                try await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
                throw VitalOsError.requestTimedOut(commandId: commandId)
            }

            let result = try await group.next()!
            group.cancelAll()

            lock.lock()
            pendingRequests.removeValue(forKey: commandId)
            lock.unlock()

            if !result.success {
                logger.warning("Request 0x\(String(commandId, radix: 16)) failed: \(result.errorMessage)")
                if result.errorCode == .unsupported {
                    throw VitalOsError.unsupportedFeature
                } else {
                    throw VitalOsError.deviceError(errorCode: result.errorCode.rawValue, message: result.errorMessage)
                }
            }

            return result
        }
    }

    public func sendRequest(commandId: Int, command: SwiftProtobuf.Message) async throws {
        try await transport.send(type: .command, commandId: commandId, payload: try command.serializedData())
    }

    public func sendStreamData(commandId: Int, data: SwiftProtobuf.Message) async throws {
        try await transport.send(type: .data, commandId: commandId, payload: try data.serializedData())
    }

    public func onResponseReceived(commandId: Int, response: CommandResponse) {
        lock.lock()
        let continuation = pendingRequests.removeValue(forKey: commandId)
        lock.unlock()

        if let continuation {
            continuation.resume(returning: response)
        } else {
            logger.warning("Received unsolicited response for command 0x\(String(commandId, radix: 16))")
        }
    }

    public func dispose() {
        lock.lock()
        let pending = pendingRequests
        pendingRequests.removeAll()
        lock.unlock()

        for (_, continuation) in pending {
            continuation.resume(throwing: VitalOsError.disconnected)
        }
    }
}
