import Foundation
import os

/// VitalOS Messaging plugin implementation.
///
/// Handles the WatchRequest → PhoneResponse protocol:
/// - REST: Proxies HTTP calls via URLSession, optionally injecting auth from ``CredentialsProvider``.
/// - Local: Routes to a registered ``LocalMessageHandler``.
/// - Raw: Routes to per-endpoint ``EndpointMessageHandler``s, then to a registered ``RawMessageHandler``.
public final class VitalOsMessagingPlugin: MessagingPlugin, @unchecked Sendable {

    private let logger = Logger(subsystem: "co.vitalos.sdk", category: "VitalOsMessagingPlugin")
    public let id = "co.vitalos.messaging"

    private var credentialsProvider: CredentialsProvider?
    private var localMessageHandler: LocalMessageHandler?
    private var rawMessageHandler: RawMessageHandler?
    private var registeredEndpoints: Set<String> = []

    /// Live map so late-registered endpoints (e.g. health) are visible to every handler instance.
    private var endpointHandlers: [String: EndpointMessageHandler] = [:]

    private var requestManager: RequestManager?

    public init() {}

    // MARK: - MessagingPlugin API

    public func registerEndpoint(_ endpoint: String, handler: @escaping EndpointMessageHandler) {
        endpointHandlers[endpoint] = handler
    }

    public func unregisterEndpoint(_ endpoint: String) {
        endpointHandlers.removeValue(forKey: endpoint)
    }

    public func sendMessage(_ request: PhoneRequest) async throws -> WatchResponse {
        guard let rm = requestManager else { throw VitalOsError.disconnected }
        let response = try await rm.sendRequestAndWait(commandId: VitalOsCommand.sendMessage.rawValue, command: request)
        return try WatchResponse(serializedBytes: response.payload)
    }

    public func registerRestEndpoint(_ endpoint: String) {
        registeredEndpoints.insert(endpoint)
    }

    public func setCredentialsProvider(_ provider: @escaping CredentialsProvider) {
        self.credentialsProvider = provider
    }

    public func registerLocalMessageHandler(_ handler: @escaping LocalMessageHandler) {
        self.localMessageHandler = handler
    }

    public func registerRawMessageHandler(_ handler: @escaping RawMessageHandler) {
        self.rawMessageHandler = handler
    }

    // MARK: - VitalOsPlugin lifecycle

    public func onDeviceConnected(
        device: VitalOsDevice,
        router: CommandRouter,
        streamRouter: StreamRouter,
        requestManager: RequestManager
    ) async {
        self.requestManager = requestManager

        logger.info("Registering messaging handlers")

        router.registerHandler(commandId: VitalOsCommand.sendMessage.rawValue) { [self] in
            WatchRequestCommandHandler(
                commandId: VitalOsCommand.sendMessage.rawValue,
                credentialsProvider: self.credentialsProvider,
                localMessageHandler: self.localMessageHandler,
                rawMessageHandler: self.rawMessageHandler,
                endpointHandlers: self.endpointHandlers,
                registeredEndpoints: self.registeredEndpoints
            )
        }
    }

    public func onDeviceDisconnected(_ device: VitalOsDevice) async {
        logger.debug("Device disconnected")
        endpointHandlers.removeAll()
        requestManager = nil
    }

    public func dispose() async {
        endpointHandlers.removeAll()
        requestManager = nil
    }
}
