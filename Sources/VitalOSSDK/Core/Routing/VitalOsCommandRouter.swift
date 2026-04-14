import Foundation
import SwiftProtobuf
import os

/// Dispatches reassembled messages from the transport layer to the appropriate handler.
public final class VitalOsCommandRouter: CommandRouter, @unchecked Sendable {

    private let logger = Logger(subsystem: "co.vitalos.sdk", category: "VitalOsCommandRouter")
    private let transport: VitalOsTransportLayer
    private let requestManager: RequestManager
    private let streamRouter: StreamRouter

    private var handlerFactories: [Int: @Sendable () -> FeatureCommandHandler] = [:]
    private var notificationFactories: [Int: @Sendable () -> NotificationHandler] = [:]
    private var messageTask: Task<Void, Never>?

    public init(transport: VitalOsTransportLayer, requestManager: RequestManager, streamRouter: StreamRouter) {
        self.transport = transport
        self.requestManager = requestManager
        self.streamRouter = streamRouter

        registerCoreHandlers()

        messageTask = Task { [weak self] in
            guard let self else { return }
            for await result in self.transport.onMessageReceived {
                await self.onMessageReceived(result)
            }
        }
    }

    private func registerCoreHandlers() {
        registerNotificationHandler(commandId: VitalOsCommand.cancelStream.rawValue) { [weak self] in
            CancelStreamNotificationHandler(streamRouter: self?.streamRouter)
        }
        registerNotificationHandler(commandId: VitalOsCommand.endStream.rawValue) { [weak self] in
            EndStreamNotificationHandler(streamRouter: self?.streamRouter)
        }
        registerNotificationHandler(commandId: VitalOsCommand.sendDataChunkAck.rawValue) { [weak self] in
            DataChunkAckNotificationHandler(streamRouter: self?.streamRouter)
        }
    }

    public func registerHandler(commandId: Int, factory: @escaping @Sendable () -> FeatureCommandHandler) {
        handlerFactories[commandId] = factory
    }

    public func registerNotificationHandler(commandId: Int, factory: @escaping @Sendable () -> NotificationHandler) {
        notificationFactories[commandId] = factory
    }

    private func onMessageReceived(_ result: ReassemblyResult) async {
        switch result.header.type {
        case .command:
            if notificationFactories[result.header.commandId] != nil {
                await handleNotification(commandId: result.header.commandId, payload: result.payload)
            } else {
                await handleCommand(commandId: result.header.commandId, payload: result.payload)
            }
        case .data:
            do {
                let chunk = try StreamDataChunk(serializedBytes: result.payload)
                streamRouter.onDataChunk(chunk)
            } catch {
                logger.warning("Failed to parse StreamDataChunk: \(error.localizedDescription)")
            }
        case .response:
            do {
                let response = try CommandResponse(serializedBytes: result.payload)
                requestManager.onResponseReceived(commandId: result.header.commandId, response: response)
            } catch {
                logger.warning("Failed to parse CommandResponse: \(error.localizedDescription)")
            }
        case .ack:
            break
        }
    }

    private func handleNotification(commandId: Int, payload: Data) async {
        guard let factory = notificationFactories[commandId] else { return }
        do {
            let handler = factory()
            await handler.handle(payload: payload)
        } catch {
            logger.error("Notification handler for 0x\(String(commandId, radix: 16)) threw: \(error.localizedDescription)")
        }
    }

    private func handleCommand(commandId: Int, payload: Data) async {
        let factory = handlerFactories[commandId]
        let response: CommandResponse

        if let factory {
            do {
                if let r = await factory().handle(payload: payload) {
                    response = r
                } else {
                    return
                }
            } catch {
                var r = CommandResponse()
                r.success = false
                r.errorCode = .unknownError
                r.errorMessage = error.localizedDescription
                response = r
            }
        } else {
            logger.warning("No handler registered for command 0x\(String(commandId, radix: 16))")
            var r = CommandResponse()
            r.success = false
            r.errorCode = .invalidCommand
            r.errorMessage = "Unsupported command"
            response = r
        }

        do {
            try await transport.send(type: .response, commandId: commandId, payload: response.serializedData())
        } catch {
            logger.warning("Failed to send response for 0x\(String(commandId, radix: 16)): \(error.localizedDescription)")
        }
    }

    public func onDisconnection() {}

    public func dispose() {
        messageTask?.cancel()
        messageTask = nil
        handlerFactories.removeAll()
        notificationFactories.removeAll()
    }
}

// MARK: - Core Stream Notification Handlers

private final class CancelStreamNotificationHandler: NotificationHandler {
    let streamRouter: StreamRouter?
    init(streamRouter: StreamRouter?) { self.streamRouter = streamRouter }

    func handle(payload: Data) async {
        guard let router = streamRouter,
              let cmd = try? CancelStream(serializedBytes: payload) else { return }
        router.onStreamCancel(cmd)
    }
}

private final class EndStreamNotificationHandler: NotificationHandler {
    let streamRouter: StreamRouter?
    init(streamRouter: StreamRouter?) { self.streamRouter = streamRouter }

    func handle(payload: Data) async {
        guard let router = streamRouter,
              let cmd = try? EndStream(serializedBytes: payload) else { return }
        router.onStreamEnd(cmd)
    }
}

private final class DataChunkAckNotificationHandler: NotificationHandler {
    let streamRouter: StreamRouter?
    init(streamRouter: StreamRouter?) { self.streamRouter = streamRouter }

    func handle(payload: Data) async {
        guard let router = streamRouter,
              let ack = try? StreamDataChunkAck(serializedBytes: payload) else { return }
        router.onAckReceived(ack)
    }
}
